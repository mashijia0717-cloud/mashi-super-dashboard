import AppKit
import CoreGraphics
import IOKit
import RustDeskDisplayTopology

enum DisplaySafetyPolicy {
    static func isManagedScreen(_ screen: NSScreen) -> Bool {
        guard let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
        return RDIsManagedVirtual(CGDisplayVendorNumber(identifier), CGDisplayModelNumber(identifier), CGDisplayIsBuiltin(identifier) != 0)
    }

    static func isVirtualScreen(_ screen: NSScreen) -> Bool {
        guard let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
        return RDQuerySystemVirtualDisplay(identifier)
    }

    static func matchesCurrentDisplay(_ requested: ConnectedDisplay, current: [ConnectedDisplay]) -> Bool {
        current.contains(requested)
    }

    static func shouldRetryRecovery(code: Int32, output: String) -> Bool {
        code != 0 || output.contains("external-available")
    }

    static var lidIsOpen: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return !(value as! Bool)
    }

    static func mayHideBuiltin(usableExternalCount: Int) -> Bool {
        usableExternalCount > 0
    }

    static func builtinMasksToRelease(builtinIDs: Set<CGDirectDisplayID>, ownedIDs: Set<CGDirectDisplayID>, usableExternalCount: Int) -> Set<CGDirectDisplayID> {
        mayHideBuiltin(usableExternalCount: usableExternalCount) ? [] : builtinIDs.intersection(ownedIDs)
    }

    static var usableExternalCount: Int {
        var snapshot = RDReadSystemTopology()
        return Int(RDUsableExternalCount(&snapshot))
    }

    static var hasHeadlessOwnedBuiltinDeadlock: Bool {
        guard lidIsOpen, usableExternalCount == 0 else { return false }
        var snapshot = RDReadSystemTopology()
        for idx in 0..<snapshot.physicalCount {
            let flags = RDPhysicalDisplayAt(&snapshot, idx).flags
            if (flags & RD_VIRTUAL) == 0 && (flags & RD_ONLINE) != 0 { return false }
        }
        let support = DisplayConsolePaths.displayPanelSupportDir
        return FileManager.default.fileExists(atPath: support + "disabled-builtin.json")
            || FileManager.default.fileExists(atPath: support + "screen-sleep-state.json")
    }

    @MainActor static var physicalScreenParametersNotification: Notification.Name {
        _ = PhysicalDisplayNotifications.shared
        return PhysicalDisplayNotifications.name
    }
    @MainActor static var physicalScreensDidWakeNotification: Notification.Name {
        _ = PhysicalDisplayNotifications.shared
        return PhysicalDisplayNotifications.screenWakeName
    }
}

@MainActor
final class DisplaySafetyRecoveryController {
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var sleeping = false
    private var systemSleeping = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var observedRemovedExternalID: CGDirectDisplayID = 0
    private let helper: (String) -> String?
    private let command: (String, [String]) async -> DisplayConsolePaths.ExecResult
    private let wait: (Int) async throws -> Void
    private let deadlockCheck: () -> Bool

    init(helper: @escaping (String) -> String? = DisplayConsolePaths.helperPath,
         command: @escaping (String, [String]) async -> DisplayConsolePaths.ExecResult = { path, args in
             await Task.detached(priority: .userInitiated) { DisplayConsolePaths.runCommand(path, args, timeout: 5) }.value
         },
         wait: @escaping (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
         deadlockCheck: @escaping () -> Bool = { DisplaySafetyPolicy.hasHeadlessOwnedBuiltinDeadlock }) {
        self.helper = helper
        self.command = command
        self.wait = wait
        self.deadlockCheck = deadlockCheck
    }

    func start() {
        guard observers.isEmpty, screenObserver == nil else { return }
        stopped = false
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, DisplaySafetyPolicy.physicalScreensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteWake()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteSystemSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteScreenSleep() }
        })
        screenObserver = NotificationCenter.default.addObserver(forName: DisplaySafetyPolicy.physicalScreenParametersNotification, object: nil, queue: .main) { [weak self] notification in
            let removed = (notification.userInfo?[PhysicalDisplayNotifications.removedExternalIDUserInfoKey] as? NSNumber)?.uint32Value ?? 0
            MainActor.assumeIsolated {
                if removed != 0 { self?.observedRemovedExternalID = removed }
                self?.handlePhysicalTopologyEvent()
            }
        }
        if !CommandLine.arguments.contains("--rd-adopt-running") { requestRecovery() }
    }

    func stop() {
        stopped = true; generation &+= 1
        recoveryTask?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    func noteSleep() {
        systemSleeping = true
        sleeping = true
        generation &+= 1
    }

    func noteSystemSleep() {
        systemSleeping = true
        sleeping = true
        generation &+= 1
    }

    func noteScreenSleep() {
        // When unplugging the only active external monitor with builtin disabled, macOS posts
        // screensDidSleepNotification because 0 displays remain active. Do not let screen-sleep
        // cancel the builtin re-enable recovery when the laptop lid is open and system is awake!
        if !systemSleeping, (observedRemovedExternalID != 0 || PhysicalDisplayNotifications.shared.lastRemovedExternalID != 0), deadlockCheck() {
            sleeping = false
            requestRecovery()
            return
        }
        sleeping = true
        generation &+= 1
    }

    func noteWake() {
        systemSleeping = false
        sleeping = false
        requestRecovery()
    }

    private func handlePhysicalTopologyEvent() {
        if sleeping && !systemSleeping && (observedRemovedExternalID != 0 || PhysicalDisplayNotifications.shared.lastRemovedExternalID != 0) && deadlockCheck() {
            sleeping = false
        }
        requestRecovery()
    }

    func requestRecovery(removedExternal: CGDirectDisplayID = 0) {
        if removedExternal != 0 { observedRemovedExternalID = removedExternal }
        guard !sleeping, !systemSleeping, !stopped else { return }
        generation &+= 1
        guard recoveryTask == nil else { return }
        recoveryTask = Task {
            defer { recoveryTask = nil }
            var attempt = 0
            while !Task.isCancelled && !sleeping && !systemSleeping && !stopped {
                do { try await wait([250, 250, 750, 2000][attempt]) } catch { return }
                guard !Task.isCancelled, !sleeping, !systemSleeping, !stopped else { return }
                let observed = generation
                guard let blank = helper("ScreenBlank"), let manager = helper("DisplayManager") else { return }
                let removal = observedRemovedExternalID
                let blankArgs = removal != 0 ? ["--recover-orphan", "--observed-removal"] : ["--recover-orphan"]
                var result = await command(blank, blankArgs)
                guard !Task.isCancelled, !sleeping, !systemSleeping, !stopped else { return }
                if generation != observed { attempt = 0; continue }
                if result.code == 0 {
                    let managerArgs = removal != 0 ? ["safety-recover", "--observed-removal", String(removal)] : ["safety-recover"]
                    result = await command(manager, managerArgs)
                }
                guard !Task.isCancelled, !sleeping, !systemSleeping, !stopped else { return }
                if generation != observed { attempt = 0; continue }
                guard DisplaySafetyPolicy.shouldRetryRecovery(code: result.code, output: result.output), attempt < 3 else {
                    if result.code == 0 && removal != 0 {
                        PhysicalDisplayNotifications.shared.clearRemovedExternalIfRecovered(removal)
                        if observedRemovedExternalID == removal { observedRemovedExternalID = 0 }
                    }
                    return
                }
                attempt += 1
            }
        }
    }
}
