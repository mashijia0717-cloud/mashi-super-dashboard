import AppKit
import CoreGraphics
import IOKit
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

/// 右键快捷场景：熄屏保后台、系统休眠与立即锁定屏幕。
@MainActor
final class DisplaySceneController {
    var onChange: (() -> Void)?

    private let keepAwake: KeepAwakeController
    private var systemSleepAssertionID: IOPMAssertionID = 0
    private var systemSleepAssertionActive = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init(keepAwake: KeepAwakeController) {
        self.keepAwake = keepAwake
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreensDidWake() }
            },
            center.addObserver(forName: DisplaySafetyPolicy.physicalScreensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreensDidWake() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreensDidWake() }
            }
        ]
    }

    func stop() {
        releaseSystemSleepAssertion()
        keepAwake.resumeDisplaySleepPrevention()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    func sleepDisplaysKeepingSystemAwake() {
        keepAwake.suspendDisplaySleepPrevention()
        takeSystemSleepAssertion()
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func sleepMac() {
        keepAwake.suspendDisplaySleepPrevention()
        releaseSystemSleepAssertion()
        run("/usr/bin/pmset", ["sleepnow"])
    }

    func lockScreen() {
        if lockScreenImmediate() { return }
        run("/usr/bin/pmset", ["displaysleepnow"])
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
            "Super Dashboard 熄屏但不休眠" as CFString,
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
