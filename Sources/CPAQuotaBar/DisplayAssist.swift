import AppKit
import IOKit.pwr_mgt

enum KeepAwakePreference {
    static let key = "keepScreenAwakeEnabled"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func save(_ value: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}

/// 通过 IOKit 断言阻止显示器休眠。用户开关会写入偏好；擦屏模式可临时加一层 hold。
@MainActor
final class KeepAwakeController {
    var onStateChanged: (() -> Void)?
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false
    private var temporaryHoldCount = 0
    private var timedExpirationDate: Date?
    private var timedExpirationTask: Task<Void, Never>?
    private let defaults: UserDefaults

    var isEnabled: Bool {
        get { KeepAwakePreference.load(from: defaults) }
        set {
            cancelTimedAwake(sync: false)
            KeepAwakePreference.save(newValue, to: defaults)
            syncAssertion()
            onStateChanged?()
        }
    }

    var isPreventingSleep: Bool {
        assertionActive
    }

    var activeTimedRemainingMinutes: Int? {
        guard let timedExpirationDate else { return nil }
        let remaining = timedExpirationDate.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining / 60)))
    }

    var statusSummary: String? {
        if let mins = activeTimedRemainingMinutes {
            return mins >= 60 ? "定时常亮剩余 \(mins / 60)h\(mins % 60)m" : "定时常亮剩余 \(mins) 分钟"
        }
        return isEnabled ? "屏幕常亮" : nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func startTimed(minutes: Int) {
        guard minutes > 0 else { return }
        KeepAwakePreference.save(false, to: defaults)
        timedExpirationTask?.cancel()
        let expiry = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timedExpirationDate = expiry
        syncAssertion()
        onStateChanged?()
        timedExpirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            self.timedExpirationDate = nil
            self.timedExpirationTask = nil
            self.syncAssertion()
            self.onStateChanged?()
        }
    }

    func cancelTimedAwake(sync: Bool = true) {
        timedExpirationTask?.cancel()
        timedExpirationTask = nil
        timedExpirationDate = nil
        if sync {
            syncAssertion()
            onStateChanged?()
        }
    }

    func start() {
        syncAssertion()
    }

    func stop() {
        temporaryHoldCount = 0
        cancelTimedAwake(sync: false)
        releaseAssertion()
    }

    func beginTemporaryHold() {
        temporaryHoldCount += 1
        syncAssertion()
    }

    func endTemporaryHold() {
        temporaryHoldCount = max(0, temporaryHoldCount - 1)
        syncAssertion()
    }

    /// 临时放开显示器休眠断言，便于立刻熄屏；偏好设置不变。
    func suspendDisplaySleepPrevention() {
        releaseAssertion()
    }

    func resumeDisplaySleepPrevention() {
        syncAssertion()
    }

    private func syncAssertion() {
        let timedActive = (timedExpirationDate?.timeIntervalSinceNow ?? -1) > 0
        if isEnabled || temporaryHoldCount > 0 || timedActive {
            takeAssertion()
        } else {
            releaseAssertion()
        }
    }

    private func takeAssertion() {
        guard !assertionActive else { return }
        var identifier: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Super Dashboard 屏幕常亮" as CFString,
            &identifier
        )
        guard status == kIOReturnSuccess else { return }
        assertionID = identifier
        assertionActive = true
    }

    private func releaseAssertion() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        assertionActive = false
    }
}

/// 全屏遮罩，方便擦拭屏幕；点击不会落到下层窗口，按 Esc 退出。
@MainActor
final class ScreenCleanModeController {
    var onDidExit: (() -> Void)?
    private(set) var isActive = false
    private var cursorHidden = false
    private var windows: [NSWindow] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []

    func enter() {
        guard !isActive else { return }
        isActive = true
        presentOverlays()
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.exit()
                return nil
            }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.exit()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: DisplaySafetyPolicy.physicalScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if NSScreen.screens.isEmpty {
                    self.exit()
                } else {
                    self.presentOverlays()
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.exit() }
            })
        }
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        tearDownMonitors()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        onDidExit?()
    }

    private func presentOverlays() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
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
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: true)
            window.contentView = ScreenCleanOverlayView { [weak self] in
                self?.exit()
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func tearDownMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers.removeAll()
    }
}

@MainActor
private final class ScreenCleanOverlayView: NSView {
    private let onExit: () -> Void
    private let hint = NSTextField(labelWithString: "擦屏模式生效中 · 按 Esc 退出")
    private var fadeTask: Task<Void, Never>?

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.28)
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
        flashHint()
    }

    private func flashHint() {
        hint.textColor = NSColor.white.withAlphaComponent(0.88)
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.hint.textColor = NSColor.white.withAlphaComponent(0.28)
        }
    }

    override func mouseDown(with event: NSEvent) { flashHint() }
    override func rightMouseDown(with event: NSEvent) { flashHint() }
    override func otherMouseDown(with event: NSEvent) { flashHint() }
}

enum PowerFlowGeometry {
    static func cubicPoint(
        t: CGFloat,
        start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        end: CGPoint
    ) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * start.x
                + 3 * u * u * t * control1.x
                + 3 * u * t * t * control2.x
                + t * t * t * end.x,
            y: u * u * u * start.y
                + 3 * u * u * t * control1.y
                + 3 * u * t * t * control2.y
                + t * t * t * end.y
        )
    }

    static func particleOffset(phase: CGFloat, index: Int, count: Int) -> CGFloat {
        let count = max(count, 1)
        return (phase + CGFloat(index) / CGFloat(count)).truncatingRemainder(dividingBy: 1)
    }

    static func particleOpacity(progress: CGFloat) -> CGFloat {
        sin(min(max(progress, 0), 1) * .pi)
    }
}
