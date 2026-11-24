import AppKit
import CoreGraphics
import RustDeskDisplayTopology

@MainActor
final class PhysicalDisplayNotifications {
    static let shared = PhysicalDisplayNotifications()
    static let name = Notification.Name("local.mashijia.physicalDisplayParametersChanged")
    static let screenWakeName = Notification.Name("local.mashijia.physicalScreensDidWake")
    nonisolated static let removedExternalIDUserInfoKey = "removedExternalID"

    private var gate: RDTopologyGate
    private var knownPhysicalExternals: Set<CGDirectDisplayID> = []
    private(set) var lastRemovedExternalID: CGDirectDisplayID = 0
    private let snapshot: () -> RDTopology
    private var emit: () -> Void
    private let emitScreenWake: () -> Void
    private var observer: NSObjectProtocol?
    private var registered = false
    private var reliableCallbacks = true
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleeping = false

    init(snapshot: @escaping () -> RDTopology = { RDReadSystemTopology() }, watchSystem: Bool = true, emit: (() -> Void)? = nil, emitScreenWake: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.emit = emit ?? {}
        self.emitScreenWake = emitScreenWake ?? { NSWorkspace.shared.notificationCenter.post(name: Self.screenWakeName, object: nil) }
        let initial = snapshot()
        gate = RDTopologyGateCreate(initial)
        rememberExternals(from: initial)
        if emit == nil {
            self.emit = { [weak self] in
                let removed = self?.lastRemovedExternalID ?? 0
                let info: [AnyHashable: Any]? = removed != 0 ? [Self.removedExternalIDUserInfoKey: removed] : nil
                NotificationCenter.default.post(name: Self.name, object: nil, userInfo: info)
            }
        }
        guard watchSystem else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        registered = CGDisplayRegisterReconfigurationCallback(Self.displayChanged, context) == .success
        if !registered {
            reliableCallbacks = false
            NSLog("Physical display callbacks unavailable; keeping original notification recovery")
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(RDEventScreenParameters) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSleep() }
            })
        }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receiveScreenWake() }
        })
    }

    private func rememberExternals(from topology: RDTopology) {
        guard topology.valid else { return }
        var copy = topology
        var currentExternals: Set<CGDirectDisplayID> = []
        for idx in 0..<copy.physicalCount {
            let row = RDPhysicalDisplayAt(&copy, idx)
            if (row.flags & RD_BUILTIN) == 0 && (row.flags & RD_VIRTUAL) == 0 && (row.flags & RD_ONLINE) != 0 {
                knownPhysicalExternals.insert(row.id)
                currentExternals.insert(row.id)
            }
        }
        if !currentExternals.isEmpty, currentExternals.contains(lastRemovedExternalID) {
            lastRemovedExternalID = 0
        }
    }

    func receive(_ event: RDEvent, display: CGDirectDisplayID = 0, flags: CGDisplayChangeSummaryFlags = []) {
        var current = snapshot()
        if flags.contains(.removeFlag), knownPhysicalExternals.contains(display) {
            lastRemovedExternalID = display
        } else if flags.contains(.addFlag) {
            for idx in 0..<current.physicalCount {
                let row = RDPhysicalDisplayAt(&current, idx)
                if row.id == display && (row.flags & RD_BUILTIN) == 0 && (row.flags & RD_VIRTUAL) == 0 {
                    lastRemovedExternalID = 0
                }
            }
        } else if current.valid {
            // Also detect implicit physical removal when an external disappears between snapshots
            var stillOnline: Set<CGDirectDisplayID> = []
            for idx in 0..<current.physicalCount {
                let row = RDPhysicalDisplayAt(&current, idx)
                if (row.flags & RD_BUILTIN) == 0 && (row.flags & RD_VIRTUAL) == 0 && (row.flags & RD_ONLINE) != 0 {
                    stillOnline.insert(row.id)
                }
            }
            if let vanished = knownPhysicalExternals.subtracting(stillOnline).first, stillOnline.isEmpty {
                lastRemovedExternalID = vanished
            }
        }
        rememberExternals(from: current)
        if !reliableCallbacks || RDTopologyShouldProcess(&gate, current, event, display) { emit() }
    }

    func clearRemovedExternalIfRecovered(_ id: CGDirectDisplayID) {
        if lastRemovedExternalID == id {
            lastRemovedExternalID = 0
            knownPhysicalExternals.remove(id)
        }
    }

    func noteSleep() { sleeping = true }
    func receiveScreenWake() {
        let event = sleeping ? RDEventWake : RDEventScreenWake
        sleeping = false
        let current = snapshot()
        rememberExternals(from: current)
        if !reliableCallbacks || RDTopologyShouldProcess(&gate, current, event, 0) { emitScreenWake() }
    }

    private nonisolated static let displayChanged: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let owner = Unmanaged<PhysicalDisplayNotifications>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { owner.receive(RDEventDisplayCallback, display: display, flags: flags) }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
    }
}
