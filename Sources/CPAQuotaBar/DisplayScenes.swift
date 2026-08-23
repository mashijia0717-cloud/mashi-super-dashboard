import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics
import IOKit.pwr_mgt

struct ConnectedDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let index: Int
    let name: String
    let isBuiltin: Bool
}

enum DisplaySceneFormatting {
    static func menuTitle(index: Int, name: String, isOff: Bool) -> String {
        let label = "关闭显示器 \(index)"
        let suffix = shortName(name)
        let titled = suffix.isEmpty ? label : "\(label)（\(suffix)）"
        return isOff ? "\(titled) · 已关闭" : titled
    }

    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 18 { return trimmed }
        return String(trimmed.prefix(16)) + "…"
    }
}

enum ConnectedDisplays {
    static func current() -> [ConnectedDisplay] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(truncating: number)
            let name = screen.localizedName
            return ConnectedDisplay(
                id: id,
                index: index + 1,
                name: name,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }
}

/// 右键场景：熄屏、休眠、锁定，以及按台关闭显示器。
@MainActor
final class DisplaySceneController {
    var onChange: (() -> Void)?

    private let keepAwake: KeepAwakeController
    private var blankWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var poweredOffIDs: Set<CGDirectDisplayID> = []
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var systemSleepAssertionActive = false
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?

    init(keepAwake: KeepAwakeController) {
        self.keepAwake = keepAwake
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreensDidWake()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreensDidWake()
                }
            }
        ]
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneDisconnectedDisplays()
            }
        }
    }

    func stop() {
        restoreAllDisplays()
        releaseSystemSleepAssertion()
        keepAwake.resumeDisplaySleepPrevention()
        tearDownKeyMonitors()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    func isDisplayOff(_ id: CGDirectDisplayID) -> Bool {
        poweredOffIDs.contains(id) || blankWindows[id] != nil
    }

    func sleepDisplaysKeepingSystemAwake() {
        keepAwake.suspendDisplaySleepPrevention()
        takeSystemSleepAssertion()
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func sleepMac() {
        restoreAllDisplays()
        keepAwake.suspendDisplaySleepPrevention()
        releaseSystemSleepAssertion()
        run("/usr/bin/pmset", ["sleepnow"])
    }

    func lockScreen() {
        if lockScreenImmediate() { return }
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func toggleDisplay(_ display: ConnectedDisplay) {
        if isDisplayOff(display.id) {
            turnOn(display)
        } else {
            turnOff(display)
        }
        onChange?()
    }

    private func turnOff(_ display: ConnectedDisplay) {
        if DisplayIOKit.setPower(display.id, on: false) {
            poweredOffIDs.insert(display.id)
            ensureKeyMonitors()
            return
        }
        presentBlank(on: display)
    }

    private func turnOn(_ display: ConnectedDisplay) {
        if poweredOffIDs.remove(display.id) != nil {
            _ = DisplayIOKit.setPower(display.id, on: true)
        }
        removeBlank(display.id)
    }

    func restoreAllDisplays() {
        for id in poweredOffIDs {
            _ = DisplayIOKit.setPower(id, on: true)
        }
        poweredOffIDs.removeAll()
        for id in Array(blankWindows.keys) {
            removeBlank(id)
        }
        tearDownKeyMonitors()
    }

    private func presentBlank(on display: ConnectedDisplay) {
        removeBlank(display.id)
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID(truncating: $0) } == display.id
        }) else { return }

        let window = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        window.contentView = DisplayOffOverlayView { [weak self] in
            self?.turnOn(display)
            self?.onChange?()
        }
        window.orderFrontRegardless()
        blankWindows[display.id] = window
        ensureKeyMonitors()
    }

    private func removeBlank(_ id: CGDirectDisplayID) {
        blankWindows[id]?.orderOut(nil)
        blankWindows.removeValue(forKey: id)
        if blankWindows.isEmpty && poweredOffIDs.isEmpty {
            tearDownKeyMonitors()
        }
    }

    private func pruneDisconnectedDisplays() {
        let connected = Set(ConnectedDisplays.current().map(\.id))
        for id in poweredOffIDs where !connected.contains(id) {
            poweredOffIDs.remove(id)
        }
        for id in Array(blankWindows.keys) where !connected.contains(id) {
            removeBlank(id)
        }
        onChange?()
    }

    private func handleScreensDidWake() {
        keepAwake.resumeDisplaySleepPrevention()
        releaseSystemSleepAssertion()
    }

    private func takeSystemSleepAssertion() {
        guard !systemSleepAssertionActive else { return }
        var identifier: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "马氏超级仪表盘 熄屏但不休眠" as CFString,
            &identifier
        )
        guard status == kIOReturnSuccess else { return }
        systemSleepAssertionID = identifier
        systemSleepAssertionActive = true
    }

    private func releaseSystemSleepAssertion() {
        guard systemSleepAssertionActive else { return }
        IOPMAssertionRelease(systemSleepAssertionID)
        systemSleepAssertionID = 0
        systemSleepAssertionActive = false
    }

    private func ensureKeyMonitors() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.restoreAllDisplays()
                self?.onChange?()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.restoreAllDisplays()
                self?.onChange?()
            }
        }
    }

    private func tearDownKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func lockScreenImmediate() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_LAZY
        ) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Void
        unsafeBitCast(symbol, to: LockFn.self)()
        return true
    }

    private func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

enum DisplayIOKit {
    static func setPower(_ displayID: CGDirectDisplayID, on: Bool) -> Bool {
        guard let service = service(for: displayID) else { return false }
        defer { IOObjectRelease(service) }
        let state: Int32 = on ? 2 : 0
        let status = IODisplaySetIntegerParameter(service, 0, "dsyp" as CFString, state)
        return status == KERN_SUCCESS
    }

    private static func service(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        let vendor = Int(CGDisplayVendorNumber(displayID))
        let model = Int(CGDisplayModelNumber(displayID))
        let serial = Int(CGDisplaySerialNumber(displayID))

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            guard let unmanaged = IODisplayCreateInfoDictionary(service, IOOptionBits(0x00000100)) else {
                IOObjectRelease(service)
                continue
            }
            let dict = unmanaged.takeRetainedValue() as NSDictionary
            let matchedVendor = (dict["DisplayVendorID"] as? NSNumber)?.intValue == vendor
            let matchedModel = (dict["DisplayProductID"] as? NSNumber)?.intValue == model
            let matchedSerial = (dict["DisplaySerialNumber"] as? NSNumber)?.intValue ?? 0 == serial
            if matchedVendor && matchedModel && (serial == 0 || matchedSerial) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }
}

@MainActor
private final class DisplayOffOverlayView: NSView {
    private let onExit: () -> Void

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let hint = NSTextField(labelWithString: "显示器已关闭 · 按 Esc 或点击点亮")
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.22)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -36)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onExit()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onExit()
    }
}
