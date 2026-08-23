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
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false
    private var temporaryHoldCount = 0
    private let defaults: UserDefaults

    var isEnabled: Bool {
        get { KeepAwakePreference.load(from: defaults) }
        set {
            KeepAwakePreference.save(newValue, to: defaults)
            syncAssertion()
        }
    }

    var isPreventingSleep: Bool {
        assertionActive
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        syncAssertion()
    }

    func stop() {
        temporaryHoldCount = 0
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
        if isEnabled || temporaryHoldCount > 0 {
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
            "马氏超级仪表盘 屏幕常亮" as CFString,
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

/// 全屏浅色遮罩，方便擦拭屏幕；点击不会落到下层窗口，按 Esc 退出。
@MainActor
final class ScreenCleanModeController {
    var onDidExit: (() -> Void)?
    private(set) var isActive = false
    private var windows: [NSWindow] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    func enter() {
        guard !isActive else { return }
        isActive = true
        presentOverlays()
        NSCursor.hide()
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
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.presentOverlays()
            }
        }
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        tearDownMonitors()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.unhide()
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
    }
}

@MainActor
private final class ScreenCleanOverlayView: NSView {
    private let onExit: () -> Void

    init(onExit: @escaping () -> Void) {
        self.onExit = onExit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let hint = NSTextField(labelWithString: "擦屏模式 · 按 Esc 退出")
        hint.font = .systemFont(ofSize: 14, weight: .medium)
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

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
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
