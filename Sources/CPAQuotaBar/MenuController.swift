import AppKit
import Foundation

// MARK: - Tokens

@MainActor
private enum Tokens {
    static let popoverSize = NSSize(width: 400, height: 600)
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 6
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 56
    static let radius: CGFloat = 10
    static let panelRadius: CGFloat = 12
    static let cardWidth = popoverSize.width - (padding * 2)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    static func menuRowFill(in view: NSView) -> CGColor {
        cgColor(.labelColor.withAlphaComponent(0.028), in: view)
    }

    static func menuRowFillHover(in view: NSView) -> CGColor {
        cgColor(.labelColor.withAlphaComponent(0.07), in: view)
    }

    static func menuRowBorder(in view: NSView) -> CGColor {
        cgColor(.labelColor.withAlphaComponent(0.05), in: view)
    }

    static func cgColor(_ color: NSColor, in view: NSView) -> CGColor {
        var result: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }

    static var cardBorder: NSColor {
        NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.85 : 0.35)
    }

    static func statusColor(remaining: Double?) -> NSColor {
        guard let r = remaining else { return .secondaryLabelColor }
        if r <= 0.2 { return .systemRed }
        if r <= 0.6 { return .systemOrange }
        return .systemGreen
    }

    static func applyMenuButtonStyle(_ button: NSButton) {
        button.isBordered = true
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .flexiblePush
        }
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.backgroundColor = nil
        button.layer?.borderWidth = 0
    }
}

// MARK: - Menu Glass Backdrop

/// 与系统右键菜单相同的雾面：优先使用 Liquid Glass，旧系统回退到 `.menu` 材质。
@MainActor
final class BlueThemeBackdropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blendingMode = .behindWindow
        state = .active
        isEmphasized = true
        layer?.cornerRadius = Tokens.panelRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        material = .menu
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }
}

@MainActor
enum MenuGlassHost {
    static func wrap(_ content: NSView, cornerRadius: CGFloat = Tokens.panelRadius) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Tokens.popoverSize))
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = content
            content.frame = glass.bounds
            content.autoresizingMask = [.width, .height]
            return glass
        }

        let host = NSView(frame: NSRect(origin: .zero, size: Tokens.popoverSize))
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        let backdrop = BlueThemeBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(backdrop)
        host.addSubview(content)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return host
    }
}

// MARK: - Menu-row card

/// 菜单式行卡片：落在整块雾面之上，不再叠一层玻璃。
@MainActor
class LiquidGlassCardView: NSView {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        applyGlassAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlassAccessibility()
    }

    func applyGlassAccessibility() {
        if Tokens.reduceTransparency {
            layer?.backgroundColor = Tokens.cgColor(.controlBackgroundColor, in: self)
            layer?.borderWidth = Tokens.increaseContrast ? 2 : 1
            layer?.borderColor = Tokens.cgColor(.separatorColor, in: self)
            return
        }
        layer?.backgroundColor = isHovered ? Tokens.menuRowFillHover(in: self) : Tokens.menuRowFill(in: self)
        layer?.borderColor = Tokens.menuRowBorder(in: self)
        layer?.borderWidth = Tokens.increaseContrast ? 1.5 : 0.5
        layer?.shadowOpacity = 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        guard !Tokens.reduceMotion else {
            applyGlassAccessibility()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            applyGlassAccessibility()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        guard !Tokens.reduceMotion else {
            applyGlassAccessibility()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            applyGlassAccessibility()
        }
    }
}

@MainActor
final class MenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: AnchoredStatusPanel
    private let contentController = QuotaPopoverViewController()
    private let menuBarSystemMonitor = SystemStatusMonitor()
    private var settingsWindowController: SettingsWindowController?
    private var menuBarSystemSnapshot: SystemStatusSnapshot?
    private var menuBarSamplingTask: Task<Void, Never>?
    private let keepAwake = KeepAwakeController()
    private let screenClean = ScreenCleanModeController()
    private lazy var displayScenes = DisplaySceneController(keepAwake: keepAwake)

    override init() {
        self.panel = AnchoredStatusPanel(contentViewController: contentController)
        super.init()
        contentController.onSettings = { [weak self] in self?.showSettings() }
        contentController.onQuit = { NSApplication.shared.terminate(nil) }
        contentController.onPreferredHeightChanged = { [weak self] height in
            self?.panel.resizeContent(to: height)
        }
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "系统仪表盘"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = AppBrand.displayName
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
        screenClean.onDidExit = { [weak self] in
            self?.keepAwake.endTemporaryHold()
            self?.updateStatusItem()
        }
        displayScenes.onChange = { [weak self] in
            self?.updateStatusItem()
        }
    }

    func start() {
        keepAwake.start()
        startMenuBarSampling()
        updateStatusItem()
    }

    func stop() {
        screenClean.exit()
        displayScenes.stop()
        keepAwake.stop()
        menuBarSamplingTask?.cancel()
        menuBarSamplingTask = nil
    }

    private func startMenuBarSampling() {
        // 菜单栏没有选择任何系统指标时，不启动昂贵的 IOKit/SMC 采样循环。
        guard MenuBarNumberOption.savedSelection().contains(where: {
            $0 == .battery || $0 == .power || $0 == .mouseBattery
        }) else { return }
        guard menuBarSamplingTask == nil else { return }
        menuBarSamplingTask = Task { [weak self, monitor = menuBarSystemMonitor] in
            while !Task.isCancelled {
                // 状态页/电源页有自己的实时采样；页面打开时暂停菜单栏采样，避免重复读取。
                if self?.panel.isVisible == true {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                // 菜单栏只显示电量/功率/鼠标电量，走轻量采样：
                // 不做 CPU/GPU/磁盘/网络与附近设备扫描。电量分钟级才变化，
                // 功率 5 秒刷新也足够跟手，这里是全天驻留循环，省下的都是持续功耗。
                let snapshot = await Task.detached(priority: .utility) {
                    monitor.sampleMenuBar()
                }.value
                guard !Task.isCancelled, let self else { return }
                self.menuBarSystemSnapshot = snapshot
                self.updateStatusItem()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func restartMenuBarSampling() {
        menuBarSamplingTask?.cancel()
        menuBarSamplingTask = nil
        startMenuBarSampling()
    }

    func showPopover() {
        guard let button = statusItem.button, !panel.isVisible else { return }
        panel.show(relativeTo: button)
        contentController.setPopoverVisible(true)
    }

    func writeDebugFrames() {
        contentController.writeDebugFrames()
    }

    func showSystemStatusPage() {
        contentController.showSystemStatusPage()
    }

    func showPowerFlowPage() {
        contentController.showPowerFlowPage()
    }

    func showStorageCleanupPage() {
        contentController.showStorageCleanupPage()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showStatusMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            panel.closePanel()
        } else {
            panel.show(relativeTo: button)
            contentController.setPopoverVisible(true)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let selected = MenuBarNumberOption.savedSelection()
        var values: [String] = []
        for option in MenuBarNumberOption.allCases where selected.contains(option) {
            switch option {
            case .battery:
                values.append(percent(menuBarSystemSnapshot?.powerFlow.batteryLevel))
            case .power:
                values.append(watts(menuBarSystemSnapshot?.powerFlow.systemWatts))
            case .mouseBattery:
                let value = menuBarSystemSnapshot?.metrics.first(where: { $0.kind == .mouseBattery })?.value
                values.append(percent(value))
            }
        }

        if values.isEmpty {
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.title = " " + values.joined(separator: "  ")
            button.imagePosition = .imageLeading
        }

        var tooltip = AppBrand.displayName
        if keepAwake.isEnabled {
            tooltip += " · 屏幕常亮"
        }
        if screenClean.isActive {
            tooltip += " · 擦屏模式"
        }
        let offDisplays = ConnectedDisplays.current().filter { displayScenes.isDisplayOff($0.id) }
        if !offDisplays.isEmpty {
            tooltip += " · 已关 \(offDisplays.map { "显示器 \($0.index)" }.joined(separator: "、"))"
        }
        button.toolTip = tooltip
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        if panel.isVisible {
            panel.closePanel()
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        addStatusMenuItem(
            menu,
            title: "屏幕常亮",
            symbol: "sun.max.fill",
            action: #selector(toggleKeepAwake),
            state: keepAwake.isEnabled ? .on : .off
        )
        addStatusMenuItem(
            menu,
            title: "擦屏模式",
            symbol: "hand.raised.fill",
            action: #selector(toggleScreenClean),
            state: screenClean.isActive ? .on : .off
        )

        menu.addItem(.separator())

        addStatusMenuItem(
            menu,
            title: "熄屏但不休眠",
            symbol: "moon.zzz",
            action: #selector(sleepDisplaysKeepingSystemAwake)
        )
        addStatusMenuItem(
            menu,
            title: "休眠",
            symbol: "moon.fill",
            action: #selector(sleepMac)
        )
        addStatusMenuItem(
            menu,
            title: "锁定屏幕",
            symbol: "lock.fill",
            action: #selector(lockScreenFromStatusMenu)
        )

        let displays = ConnectedDisplays.current()
        if !displays.isEmpty {
            menu.addItem(.separator())
            for display in displays {
                let item = addStatusMenuItem(
                    menu,
                    title: DisplaySceneFormatting.menuTitle(
                        index: display.index,
                        name: display.name,
                        isOff: displayScenes.isDisplayOff(display.id)
                    ),
                    symbol: display.isBuiltin ? "laptopcomputer" : "display",
                    action: #selector(toggleDisplayFromStatusMenu(_:)),
                    state: displayScenes.isDisplayOff(display.id) ? .on : .off
                )
                item.representedObject = NSNumber(value: display.id)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsFromStatusMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出 \(AppBrand.displayName)",
            action: #selector(quitFromStatusMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @discardableResult
    private func addStatusMenuItem(
        _ menu: NSMenu,
        title: String,
        symbol: String,
        action: Selector,
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        item.image = image
        menu.addItem(item)
        return item
    }

    @objc private func toggleKeepAwake() {
        keepAwake.isEnabled.toggle()
        updateStatusItem()
    }

    @objc private func toggleScreenClean() {
        if screenClean.isActive {
            screenClean.exit()
            return
        }
        if panel.isVisible {
            panel.closePanel()
        }
        keepAwake.beginTemporaryHold()
        screenClean.enter()
        updateStatusItem()
    }

    @objc private func sleepDisplaysKeepingSystemAwake() {
        if panel.isVisible {
            panel.closePanel()
        }
        displayScenes.sleepDisplaysKeepingSystemAwake()
        updateStatusItem()
    }

    @objc private func sleepMac() {
        if panel.isVisible {
            panel.closePanel()
        }
        displayScenes.sleepMac()
    }

    @objc private func lockScreenFromStatusMenu() {
        if panel.isVisible {
            panel.closePanel()
        }
        displayScenes.lockScreen()
    }

    @objc private func toggleDisplayFromStatusMenu(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(truncating: number)
        guard let display = ConnectedDisplays.current().first(where: { $0.id == id }) else { return }
        if panel.isVisible {
            panel.closePanel()
        }
        displayScenes.toggleDisplay(display)
        updateStatusItem()
    }

    @objc private func openSettingsFromStatusMenu() {
        showSettings()
    }

    @objc private func quitFromStatusMenu() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1fW", $0) } ?? "--"
    }

    func showSettingsWindow() {
        showSettings()
    }

    private func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            controller.onSettingsSaved = { [weak self] in
                self?.keepAwake.start()
                self?.restartMenuBarSampling()
                self?.updateStatusItem()
                self?.contentController.refreshLayout()
            }
            settingsWindowController = controller
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class QuotaPopoverViewController: NSViewController {
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPreferredHeightChanged: ((CGFloat) -> Void)?

    private let rootStack = NSStackView()
    private let scrollView = NSScrollView()
    private let accountStack = NSStackView()
    private let refreshButton = NSButton()
    private let refreshSpin = NSProgressIndicator()
    private let headerTitleLabel = NSTextField(labelWithString: "系统状态")
    private let updatedLabel = NSTextField(labelWithString: "尚未刷新")
    private let pageControl = NSSegmentedControl(labels: ["状态", "运行", "电源", "清理"], trackingMode: .selectOne, target: nil, action: nil)
    private var pageControlWidthConstraint: NSLayoutConstraint?
    private var selectedPage = 1
    private var segmentPages = [1, 2, 3, 4]
    private let systemMonitor = SystemStatusMonitor()
    private let runningAppsMonitor = RunningAppsMonitor()
    private var systemSamplingTask: Task<Void, Never>?
    private var appsSamplingTask: Task<Void, Never>?
    private var runningApps: [RunningApp] = []
    private var cleanupDashboard: StorageCleanupDashboardView?
    private var cleanupScanTask: Task<Void, Never>?
    private var cleanupScanCancellation: CleanupScanCancellation?
    private var runningAppsSortMode = RunningAppsSortMode(
        rawValue: UserDefaults.standard.string(forKey: "runningAppsSortMode") ?? ""
    ) ?? .memory
    private var systemCards: [SystemMetric.Kind: SystemMetricCard] = [:]
    private var powerDashboard: PowerFlowDashboardView?
    private var isPopoverVisible = false
    private var accessibilityObserver: NSObjectProtocol?
    private var viewHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        let content = NSView(frame: NSRect(origin: .zero, size: Tokens.popoverSize))
        content.wantsLayer = true

        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: content.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        view = MenuGlassHost.wrap(content)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: Tokens.popoverSize.height)
        viewHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Tokens.popoverSize.width),
            heightConstraint
        ])

        rootStack.addArrangedSubview(makeHeader())

        configureVisiblePages()
        rootStack.addArrangedSubview(separator())

        accountStack.orientation = .vertical
        accountStack.alignment = .width
        accountStack.distribution = .fill
        accountStack.spacing = Tokens.spacing
        accountStack.edgeInsets = NSEdgeInsets(top: 8, left: Tokens.padding, bottom: Tokens.padding, right: Tokens.padding)
        accountStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(accountStack)
        NSLayoutConstraint.activate([
            accountStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            accountStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            accountStack.topAnchor.constraint(equalTo: document.topAnchor),
            accountStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            accountStack.widthAnchor.constraint(equalToConstant: Tokens.popoverSize.width),
            document.widthAnchor.constraint(equalToConstant: Tokens.popoverSize.width)
        ])

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        rootStack.addArrangedSubview(scrollView)

        preferredContentSize = Tokens.popoverSize

        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyAccessibilityAppearance()
                self?.renderSelectedPage()
            }
        }
        applyAccessibilityAppearance()
    }

    private func applyAccessibilityAppearance() {
        view.wantsLayer = true
        view.layer?.backgroundColor = Tokens.reduceTransparency
            ? Tokens.cgColor(.windowBackgroundColor, in: view)
            : NSColor.clear.cgColor
        accountStack.arrangedSubviews.compactMap { $0 as? LiquidGlassCardView }.forEach {
            $0.applyGlassAccessibility()
        }
    }

    func refreshLayout() {
        guard isViewLoaded else { return }
        configureVisiblePages()
        renderSelectedPage()
    }

    private func renderSelectedPage() {
        stopSystemSampling()
        stopAppsSampling()
        stopCleanupScanning()
        systemCards.removeAll()
        powerDashboard = nil
        cleanupDashboard = nil
        accountStack.arrangedSubviews.forEach {
            accountStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch selectedPage {
        case 1:
            renderSystemStatusPage()
            updateSystemSamplingState()
        case 2:
            renderRunningAppsPage()
            updateAppsSamplingState()
        case 3:
            renderPowerFlowPage()
            updateSystemSamplingState()
        case 4:
            renderStorageCleanupPage()
        default:
            renderSystemStatusPage()
            updateSystemSamplingState()
        }
        updateHeaderForSelectedPage()
        DispatchQueue.main.async { [weak self] in
            self?.scrollToTop()
            self?.updatePreferredHeight()
        }
    }

    private func updatePreferredHeight() {
        view.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        accountStack.layoutSubtreeIfNeeded()
        let contentHeight = measuredAccountContentHeight()
        if let document = scrollView.documentView {
            let viewportHeight = scrollView.contentView.bounds.height
            let documentHeight = max(contentHeight, viewportHeight)
            if abs(document.frame.height - documentHeight) > 1 {
                document.setFrameSize(NSSize(width: Tokens.popoverSize.width, height: documentHeight))
            }
        }
        let desired = min(
            Tokens.popoverSize.height,
            max(260, Tokens.headerHeight + contentHeight + 2)
        )
        guard abs((viewHeightConstraint?.constant ?? desired) - desired) > 1 else { return }
        viewHeightConstraint?.constant = desired
        preferredContentSize = NSSize(width: Tokens.popoverSize.width, height: desired)
        onPreferredHeightChanged?(desired)
    }

    private func measuredAccountContentHeight() -> CGFloat {
        let arranged = accountStack.arrangedSubviews.filter { !$0.isHidden }
        let rowsHeight = arranged.reduce(CGFloat.zero) { total, view in
            let fittingHeight = view.fittingSize.height
            let intrinsicHeight = view.intrinsicContentSize.height
            let height = max(
                fittingHeight.isFinite && fittingHeight > 0 ? fittingHeight : 0,
                intrinsicHeight.isFinite && intrinsicHeight > 0 ? intrinsicHeight : 0
            )
            return total + height
        }
        let spacing = CGFloat(max(0, arranged.count - 1)) * accountStack.spacing
        return accountStack.edgeInsets.top + rowsHeight + spacing + accountStack.edgeInsets.bottom
    }

    private func renderSystemStatusPage() {
        let placeholders = [
            SystemMetric(kind: .cpu, title: "CPU", detail: "正在采样…", value: nil, accessibilityHelp: "所有处理器核心当前总使用率"),
            SystemMetric(kind: .gpu, title: "GPU", detail: "正在采样…", value: nil, accessibilityHelp: "图形处理器当前设备利用率"),
            SystemMetric(kind: .memory, title: "内存", detail: "正在采样…", value: nil, accessibilityHelp: "物理内存当前使用比例"),
            SystemMetric(kind: .disk, title: "磁盘", detail: "正在采样…", value: nil, accessibilityHelp: "启动磁盘已使用容量比例"),
            SystemMetric(kind: .power, title: "功率", detail: "正在读取…", value: nil, accessibilityHelp: "Apple 电源遥测中的当前系统实际功耗"),
            SystemMetric(kind: .network, title: "网络", detail: "正在采样…", value: nil, accessibilityHelp: "当前网络上传与下载速率"),
            SystemMetric(kind: .battery, title: "电池", detail: "正在读取…", value: nil, accessibilityHelp: "电池电量、充电状态与健康信息"),
            SystemMetric(kind: .mouseBattery, title: "鼠标", detail: "正在读取…", value: nil, accessibilityHelp: "已连接鼠标的剩余电量")
        ]
        for metric in placeholders {
            let card = SystemMetricCard(metric: metric)
            systemCards[metric.kind] = card
            accountStack.addArrangedSubview(card)
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        updateSystemSamplingState()
        updateAppsSamplingState()
    }

    func showSystemStatusPage() {
        loadViewIfNeeded()
        selectedPage = 1
        pageControl.selectedSegment = segmentPages.firstIndex(of: 1) ?? 0
        renderSelectedPage()
    }

    func showPowerFlowPage() {
        loadViewIfNeeded()
        selectedPage = 3
        pageControl.selectedSegment = segmentPages.firstIndex(of: 3) ?? 0
        renderSelectedPage()
    }

    func showStorageCleanupPage() {
        loadViewIfNeeded()
        selectedPage = 4
        pageControl.selectedSegment = segmentPages.firstIndex(of: 4) ?? 0
        renderSelectedPage()
    }

    private func renderPowerFlowPage() {
        let dashboard = PowerFlowDashboardView()
        powerDashboard = dashboard
        dashboard.onHeightChanged = { [weak self] in
            self?.updatePreferredHeight()
        }
        accountStack.addArrangedSubview(dashboard)
    }

    private func renderStorageCleanupPage() {
        let dashboard = StorageCleanupDashboardView()
        cleanupDashboard = dashboard
        dashboard.onScan = { [weak self] in self?.scanStorageCleanup() }
        dashboard.onClean = { [weak self] items in
            self?.confirmStorageCleanup(items: items)
        }
        dashboard.onHeightChanged = { [weak self] in self?.updatePreferredHeight() }
        accountStack.addArrangedSubview(dashboard)
    }

    private func stopCleanupScanning() {
        cleanupScanTask?.cancel()
        cleanupScanTask = nil
        cleanupScanCancellation?.cancel()
        cleanupScanCancellation = nil
    }

    private func scanStorageCleanup() {
        guard selectedPage == 4, let dashboard = cleanupDashboard else { return }
        stopCleanupScanning()
        dashboard.setScanning(true)
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let cancellation = CleanupScanCancellation()
        cleanupScanCancellation = cancellation
        cleanupScanTask = Task { [weak self, weak dashboard] in
            let snapshot = await Task.detached(priority: .utility) {
                StorageCleanupService.scan(
                    runningBundleIdentifiers: runningBundleIdentifiers,
                    shouldContinue: { !cancellation.isCancelled }
                )
            }.value
            guard !Task.isCancelled, let self, self.selectedPage == 4 else { return }
            dashboard?.setScanning(false)
            dashboard?.apply(snapshot: snapshot)
            self.updatedLabel.stringValue = "扫描于 \(snapshot.scannedAt.formatted(date: .omitted, time: .shortened))"
            self.cleanupScanTask = nil
            DispatchQueue.main.async { [weak self] in
                self?.updatePreferredHeight()
            }
        }
    }

    private func confirmStorageCleanup(items: [StorageCleanupItem]) {
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清理选中的储存空间？"
        alert.informativeText = "将把 \(items.count) 项（约 \(formatStorageBytes(items.reduce(0) { $0 + $1.bytes }))）移入废纸篓。不会删除文档、照片或项目源文件。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let dashboard = cleanupDashboard else { return }
        stopCleanupScanning()
        dashboard.setScanning(true)
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let cancellation = CleanupScanCancellation()
        cleanupScanCancellation = cancellation
        cleanupScanTask = Task { [weak self, weak dashboard] in
            let result = await Task.detached(priority: .utility) {
                StorageCleanupService.remove(
                    items: items,
                    runningBundleIdentifiers: runningBundleIdentifiers,
                    shouldContinue: { !cancellation.isCancelled }
                )
            }.value
            let freshSnapshot = await Task.detached(priority: .utility) {
                StorageCleanupService.scan(
                    runningBundleIdentifiers: runningBundleIdentifiers,
                    shouldContinue: { !cancellation.isCancelled }
                )
            }.value
            guard !Task.isCancelled, let self, self.selectedPage == 4 else { return }
            dashboard?.setScanning(false)
            let message: String
            if result.removedCount > 0 {
                message = "已移入废纸篓 \(result.removedCount) 项，释放约 \(formatStorageBytes(result.reclaimedBytes))"
            } else if let firstError = result.errors.first {
                message = "没有可移入的项目：\(firstError)"
            } else {
                message = "没有项目被移入废纸篓"
            }
            dashboard?.apply(snapshot: freshSnapshot, message: message)
            self.updatedLabel.stringValue = "清理完成 · \(Date().formatted(date: .omitted, time: .shortened))"
            self.cleanupScanTask = nil
            DispatchQueue.main.async { [weak self] in self?.updatePreferredHeight() }
        }
    }

    private func formatStorageBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func updateSystemSamplingState() {
        guard isPopoverVisible && (selectedPage == 1 || selectedPage == 3) else {
            stopSystemSampling()
            return
        }
        guard systemSamplingTask == nil else { return }
        systemSamplingTask = Task { [weak self, systemMonitor] in
            while !Task.isCancelled {
                let wantsPackDetail = self?.selectedPage == 3
                let snapshot = await Task.detached(priority: .utility) {
                    systemMonitor.sample(includeBatteryPackDetail: wantsPackDetail)
                }.value
                guard !Task.isCancelled, let self,
                      self.isPopoverVisible,
                      (self.selectedPage == 1 || self.selectedPage == 3) else {
                    return
                }
                self.applySystemSnapshot(snapshot)
                // 功率、CPU、GPU 等 Mac 指标保持短周期采样；附近设备仍由其自身的 5 分钟缓存控制。
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopSystemSampling() {
        systemSamplingTask?.cancel()
        systemSamplingTask = nil
        let monitor = systemMonitor
        Task.detached(priority: .utility) { monitor.resetTransientState() }
    }

    private func applySystemSnapshot(_ snapshot: SystemStatusSnapshot) {
        DashboardNotificationManager.shared.evaluatePower(snapshot.powerFlow)
        for metric in snapshot.metrics {
            systemCards[metric.kind]?.update(metric)
        }
        powerDashboard?.update(snapshot.powerFlow)
        if selectedPage == 3 {
            updatedLabel.stringValue =
                "Mac \(snapshot.powerFlow.sampledAt.formatted(date: .omitted, time: .standard)) · 设备每 5 分钟"
        } else if selectedPage == 1 {
            updatedLabel.stringValue = "实时更新于 \(snapshot.powerFlow.sampledAt.formatted(date: .omitted, time: .standard))"
        }
    }

    private func renderRunningAppsPage() {
        if runningApps.isEmpty {
            accountStack.addArrangedSubview(messageView(icon: "arrow.triangle.2.circlepath", text: "正在读取运行中应用…", color: .secondaryLabelColor))
            return
        }
        let toolbar = RunningAppsToolbarView(mode: runningAppsSortMode)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
        toolbar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        toolbar.onChange = { [weak self] mode in
            guard let self else { return }
            self.runningAppsSortMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "runningAppsSortMode")
            self.refreshRunningAppsPage()
        }
        accountStack.addArrangedSubview(toolbar)

        let sortedApps: [RunningApp]
        switch runningAppsSortMode {
        case .memory:
            sortedApps = runningApps.sorted { $0.residentMemoryBytes > $1.residentMemoryBytes }
        case .cpu:
            sortedApps = runningApps.sorted { ($0.cpuUsage ?? -1) > ($1.cpuUsage ?? -1) }
        case .duration:
            sortedApps = runningApps.sorted { $0.runningDuration > $1.runningDuration }
        case .name:
            sortedApps = runningApps.sorted {
                $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
            }
        }
        for app in sortedApps {
            let row = RunningAppRowView(app: app)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
            row.heightAnchor.constraint(equalToConstant: 52).isActive = true
            row.onKill = { [weak self] in self?.confirmForceQuit(app) }
            accountStack.addArrangedSubview(row)
        }
    }

    private func updateAppsSamplingState() {
        guard isPopoverVisible, selectedPage == 2 else {
            stopAppsSampling()
            return
        }
        guard appsSamplingTask == nil else { return }
        appsSamplingTask = Task { [weak self, runningAppsMonitor] in
            while !Task.isCancelled {
                let candidates = runningAppsMonitor.candidates()
                let apps = await Task.detached(priority: .utility) {
                    runningAppsMonitor.sample(candidates)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.runningApps = apps
                self.refreshRunningAppsPage()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopAppsSampling() {
        appsSamplingTask?.cancel()
        appsSamplingTask = nil
    }

    private func refreshRunningAppsPage() {
        guard selectedPage == 2 else { return }
        accountStack.arrangedSubviews.forEach {
            accountStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        renderRunningAppsPage()
    }

    private func confirmForceQuit(_ app: RunningApp) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "强制退出“\(app.localizedName)”？"
        alert.informativeText = "未保存内容会丢失。此操作只针对当前识别到的应用进程。"
        alert.addButton(withTitle: "强制退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = runningAppsMonitor.forceTerminate(app.identity)
        switch result {
        case .terminated:
            runningApps.removeAll { $0.identity == app.identity }
            refreshRunningAppsPage()
        case .applicationNotRunning:
            showActionError("应用已退出")
        case .identityChanged:
            showActionError("应用进程已变化，列表将重新刷新")
        case .requestRejected:
            showActionError("系统拒绝强制退出请求")
        }
    }

    private func showActionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func changePage() {
        guard segmentPages.indices.contains(pageControl.selectedSegment) else { return }
        selectedPage = segmentPages[pageControl.selectedSegment]
        renderSelectedPage()
        scrollToTop()
    }

    private func scrollToTop() {
        guard let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func writeDebugFrames() {
        guard let window = view.window else { return }
        let screens = NSScreen.screens.map { screen -> [String: Any] in
            ["x": screen.frame.origin.x, "y": screen.frame.origin.y, "width": screen.frame.width, "height": screen.frame.height]
        }
        let systemMetrics = systemCards.values.map { $0.debugSnapshot }
        let object: [String: Any] = ["window": ["x": window.frame.origin.x, "y": window.frame.origin.y, "width": window.frame.width, "height": window.frame.height], "screens": screens, "systemMetrics": systemMetrics]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/cpa-frames.json"))
        }
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.heightAnchor.constraint(equalToConstant: Tokens.headerHeight).isActive = true

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.target = self
        pageControl.action = #selector(changePage)
        pageControl.segmentDistribution = .fillEqually
        pageControl.segmentStyle = .capsule
        pageControl.controlSize = .large
        pageControl.font = .systemFont(ofSize: 11.5, weight: .semibold)
        pageControl.setAccessibilityLabel("页面切换")
        pageControl.toolTip = "切换状态、运行应用、电源流向和储存清理页面"

        refreshButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        refreshButton.imagePosition = .imageOnly
        refreshButton.controlSize = .regular
        Tokens.applyMenuButtonStyle(refreshButton)
        refreshButton.target = self
        refreshButton.action = #selector(showMoreMenu(_:))
        refreshButton.toolTip = "页面与更多操作"
        refreshButton.setAccessibilityLabel("更多")
        refreshButton.setAccessibilityHelp("打开设置或退出")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        refreshSpin.style = .spinning
        refreshSpin.controlSize = .small
        refreshSpin.translatesAutoresizingMaskIntoConstraints = false
        refreshSpin.isHidden = true

        container.addSubview(pageControl)
        container.addSubview(refreshButton)
        container.addSubview(refreshSpin)

        let pageWidth = pageControl.widthAnchor.constraint(equalToConstant: 292)
        pageControlWidthConstraint = pageWidth
        NSLayoutConstraint.activate([
            pageControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pageControl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pageWidth,
            pageControl.heightAnchor.constraint(equalToConstant: 30),

            refreshButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Tokens.padding),
            refreshButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 30),
            refreshButton.heightAnchor.constraint(equalToConstant: 30),

            refreshSpin.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),
            refreshSpin.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor)
        ])
        return container
    }

    private func updateHeaderForSelectedPage() {
        switch selectedPage {
        case 1:
            headerTitleLabel.stringValue = "系统状态"
            updatedLabel.stringValue = "每 1 秒实时更新"
        case 2:
            headerTitleLabel.stringValue = "运行中"
            updatedLabel.stringValue = "实时应用监测"
        case 3:
            headerTitleLabel.stringValue = "电源流向"
            updatedLabel.stringValue = "Mac 每 1 秒 · 设备每 5 分钟"
        default:
            headerTitleLabel.stringValue = "清理储存空间"
            updatedLabel.stringValue = "按需扫描 · 移入废纸篓"
        }
    }

    private func configureVisiblePages() {
        let defaults = UserDefaults.standard
        let orderMode = defaults.string(forKey: "dashboardPageOrder") ?? "default"
        let baseOrder: [Int]
        switch orderMode {
        case "powerFirst": baseOrder = [3, 1, 2, 4]
        case "statusFirst": baseOrder = [1, 3, 2, 4]
        case "cleanFirst": baseOrder = [4, 1, 2, 3]
        default: baseOrder = [1, 2, 3, 4]
        }
        segmentPages = baseOrder.filter { page in
            let key = "dashboardPageVisible\(page)"
            return defaults.object(forKey: key) as? Bool ?? true
        }
        if segmentPages.isEmpty { segmentPages = [1] }
        if !segmentPages.contains(selectedPage) { selectedPage = segmentPages[0] }
        let labels = [1: "状态", 2: "运行", 3: "电源", 4: "清理"]
        pageControl.segmentCount = segmentPages.count
        pageControlWidthConstraint?.constant = min(
            292,
            max(128, CGFloat(segmentPages.count) * 78)
        )
        for (segment, page) in segmentPages.enumerated() {
            pageControl.setLabel(labels[page] ?? "", forSegment: segment)
        }
        pageControl.selectedSegment = segmentPages.firstIndex(of: selectedPage) ?? 0
    }

    private func makeFooter() -> NSView {
        let container = NSView()
        container.heightAnchor.constraint(equalToConstant: Tokens.footerHeight).isActive = true

        let settings = NSButton(title: "设置", target: self, action: #selector(settings))
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.font = .systemFont(ofSize: 12, weight: .semibold)
        Tokens.applyMenuButtonStyle(settings)
        settings.setAccessibilityLabel("打开设置")
        settings.setAccessibilityHelp("管理菜单栏数字、显示页面与提醒")
        settings.translatesAutoresizingMaskIntoConstraints = false

        let quit = NSButton(title: "退出", target: self, action: #selector(quit))
        quit.font = .systemFont(ofSize: 12, weight: .semibold)
        Tokens.applyMenuButtonStyle(quit)
        quit.setAccessibilityLabel("退出 \(AppBrand.displayName)")
        quit.setAccessibilityHelp("关闭菜单栏应用")
        quit.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(settings)
        container.addSubview(quit)

        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Tokens.padding),
            settings.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            settings.heightAnchor.constraint(equalToConstant: 38),
            settings.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            quit.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Tokens.padding),
            quit.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            quit.heightAnchor.constraint(equalToConstant: 38),
            quit.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
        return container
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.45)
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func messageView(icon: String, text: String, color: NSColor) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)

        let image = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)!)
        image.contentTintColor = color
        image.symbolConfiguration = .init(pointSize: 32, weight: .regular)

        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = 4

        stack.addArrangedSubview(image)
        stack.addArrangedSubview(label)
        return stack
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "退出 \(AppBrand.displayName)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY - 4),
            in: sender
        )
    }

    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }
}

@MainActor
final class SystemMetricCard: LiquidGlassCardView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let progress = QuotaProgressBar(value: 0, color: .secondaryLabelColor)
    private var kind: SystemMetric.Kind
    private var currentMetric: SystemMetric

    var debugSnapshot: [String: Any] {
        ["kind": kind.rawValue, "detail": currentMetric.detail, "value": currentMetric.clampedValue as Any]
    }

    init(metric: SystemMetric) {
        kind = metric.kind
        currentMetric = metric
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
        heightAnchor.constraint(equalToConstant: 60).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: symbol(for: metric.kind),
                accessibilityDescription: nil
            )!
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let title = NSTextField(labelWithString: metric.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.alignment = .right
        row.addArrangedSubview(icon)
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(valueLabel)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(progress)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        update(metric)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ metric: SystemMetric) {
        kind = metric.kind
        currentMetric = metric
        valueLabel.stringValue = metric.detail
        valueLabel.textColor = color(for: metric)
        progress.update(value: metric.clampedValue ?? 0, color: color(for: metric), animated: !Tokens.reduceMotion)
        setAccessibilityRole(.group)
        setAccessibilityLabel(metric.title)
        setAccessibilityValue(metric.detail)
        setAccessibilityHelp(metric.accessibilityHelp)
    }

    private func color(for metric: SystemMetric) -> NSColor {
        guard let value = metric.clampedValue else { return .secondaryLabelColor }
        if metric.kind == .power { return .systemBlue }
        if metric.kind == .battery || metric.kind == .mouseBattery {
            if value <= 0.2 { return .systemRed }
            if value <= 0.4 { return .systemOrange }
            return .systemGreen
        }
        if value >= 0.9 { return .systemRed }
        if value >= 0.7 { return .systemOrange }
        return .systemGreen
    }

    private func symbol(for kind: SystemMetric.Kind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        case .network: return "arrow.up.arrow.down"
        case .battery: return "battery.75percent"
        case .mouseBattery: return "computermouse"
        }
    }
}

final class QuotaProgressBar: NSView {
    private var value: CGFloat
    private var color: NSColor

    init(value: Double, color: NSColor) {
        self.value = CGFloat(min(max(value, 0), 1))
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: Double, color: NSColor, animated: Bool) {
        self.value = CGFloat(min(max(value, 0), 1))
        self.color = color
        setAccessibilityValue(value)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().needsDisplay = true
            }
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.separatorColor.withAlphaComponent(0.12).setFill()
        track.fill()
        guard value > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color.setFill()
        fill.fill()
    }
}

/// 存储扫描运行在 detached 任务里，Task.cancel() 传不进去；
/// 用这个标志把“页面已关闭”通知到扫描内部，让它尽快停止磁盘遍历。
final class CleanupScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - Anchored Status Panel

@MainActor
final class AnchoredStatusPanel: NSPanel {
    private var clickEventMonitor: Any?
    private var localMouseMonitor: Any?
    private var keyEventMonitor: Any?
    private var anchorScreenRect: NSRect?
    private weak var anchorScreen: NSScreen?

    override var canBecomeKey: Bool { true }
    private var keepsOpenForDebugCapture: Bool { CommandLine.arguments.contains("--show") }

    init(contentViewController: NSViewController) {
        let size = Tokens.popoverSize
        let rect = NSRect(origin: .zero, size: size)
        super.init(contentRect: rect,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)

        self.isFloatingPanel = true
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.contentViewController = contentViewController
        self.animationBehavior = .none // 自定义动画

        setupEventMonitors()
    }

    private func setupEventMonitors() {
        clickEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.window !== self { self.closePanel() }
            return event
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard self?.isVisible == true else { return event }
            if event.keyCode == 53 { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidResignActive() {
        if !keepsOpenForDebugCapture { closePanel() }
    }

    func closePanel() {
        if isVisible {
            close()
            if let vc = contentViewController as? QuotaPopoverViewController {
                vc.setPopoverVisible(false)
            }
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRect)
        let screen = screen(containing: buttonScreenRect, fallback: window.screen)
        anchorScreenRect = buttonScreenRect
        anchorScreen = screen
        let target = frameFor(anchor: buttonScreenRect, on: screen, height: Tokens.popoverSize.height)
        setFrame(target, display: false)
        makeKeyAndOrderFront(nil)
    }

    private func screen(containing rect: NSRect, fallback: NSScreen?) -> NSScreen {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? fallback
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func frameFor(anchor: NSRect, on screen: NSScreen, height: CGFloat) -> NSRect {
        let size = NSSize(width: Tokens.popoverSize.width, height: height)
        let visible = screen.visibleFrame
        let x = min(
            max(anchor.midX - size.width / 2, visible.minX + 8),
            visible.maxX - size.width - 8
        )
        let belowY = anchor.minY - size.height - 6
        let aboveY = anchor.maxY + 6
        let y: CGFloat
        if belowY >= visible.minY {
            y = min(belowY, visible.maxY - size.height)
        } else if aboveY + size.height <= visible.maxY {
            y = aboveY
        } else {
            y = max(visible.minY, min(belowY, visible.maxY - size.height))
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func resizeContent(to height: CGFloat) {
        let clamped = min(max(height, 260), Tokens.popoverSize.height)
        guard abs(frame.height - clamped) > 1 else { return }
        let target: NSRect
        if let anchorScreenRect, let anchorScreen {
            target = frameFor(anchor: anchorScreenRect, on: anchorScreen, height: clamped)
        } else {
            var fallback = frame
            fallback.origin.y = frame.maxY - clamped
            fallback.size.height = clamped
            target = fallback
        }
        setFrame(target, display: true, animate: !Tokens.reduceMotion && isVisible)
    }

    override func cancelOperation(_ sender: Any?) {
        closePanel()
    }

    override func resignKey() {
        super.resignKey()
        if !keepsOpenForDebugCapture { closePanel() }
    }
}
