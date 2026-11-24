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
            let host = NSView(frame: NSRect(origin: .zero, size: Tokens.popoverSize))
            host.wantsLayer = true
            host.layer?.cornerRadius = cornerRadius
            host.layer?.cornerCurve = .continuous
            host.layer?.masksToBounds = true

            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Tokens.popoverSize))
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.translatesAutoresizingMaskIntoConstraints = false
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(glass)
            host.addSubview(content)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                glass.topAnchor.constraint(equalTo: host.topAnchor),
                glass.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            return host
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
            options: [.activeAlways, .mouseEnteredAndExited],
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
    private var loadedPanel: AnchoredStatusPanel?
    private var loadedContentController: QuotaPopoverViewController?
    private var panel: AnchoredStatusPanel {
        if let loadedPanel { return loadedPanel }
        let created = AnchoredStatusPanel(contentViewController: contentController)
        loadedPanel = created
        created.resizeContent(to: contentController.preferredContentSize)
        return created
    }
    private var contentController: QuotaPopoverViewController {
        if let loadedContentController { return loadedContentController }
        let created = makeContentController()
        loadedContentController = created
        return created
    }
    private let menuBarSystemMonitor = SystemStatusMonitor()
    private var settingsWindowController: SettingsWindowController?
    private var menuBarSystemSnapshot: SystemStatusSnapshot?
    private var menuBarUsageMetrics: [SystemMetric] = []
    private var menuBarSamplingTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displaysSleeping = false
    private var lastIconSignature: String?
    private let keepAwake = KeepAwakeController()
    private let screenClean = ScreenCleanModeController()
    private lazy var displayScenes = DisplaySceneController(keepAwake: keepAwake)
    private let displaySafetyRecovery = DisplaySafetyRecoveryController()

    override init() {
        super.init()
        if let button = statusItem.button {
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

    private func makeContentController() -> QuotaPopoverViewController {
        let controller = QuotaPopoverViewController()
        controller.onSettings = { [weak self] in self?.showSettings() }
        controller.onQuit = { NSApplication.shared.terminate(nil) }
        controller.onPreferredSizeChanged = { [weak self] size in
            self?.loadedPanel?.resizeContent(to: size)
        }
        controller.keepAwakeController = keepAwake
        controller.screenCleanController = screenClean
        controller.onStatusBarNeedsUpdate = { [weak self] in self?.updateStatusItem() }
        return controller
    }

    func start() {
        displaySafetyRecovery.start()
        keepAwake.start()
        IntegratedHotCornerController.shared.sync()
        AutoBrightnessController.shared.sync(deferFirstSample: CommandLine.arguments.contains("--rd-adopt-running"))
        CoreAudioDeviceManager.shared.enforceBuiltinMicrophoneIfNeeded()
        observeDisplaySleep()
        startMenuBarSampling()
        updateStatusItem()
    }

    func stop() {
        displaySafetyRecovery.stop()
        loadedPanel?.closePanel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        screenClean.exit()
        displayScenes.stop()
        keepAwake.stop()
        IntegratedHotCornerController.shared.stopPolling()
        AutoBrightnessController.shared.stop()
        menuBarSamplingTask?.cancel()
        menuBarSamplingTask = nil
    }

    private func startMenuBarSampling() {
        guard menuBarSamplingTask == nil, !displaysSleeping else { return }
        menuBarSamplingTask = Task { [weak self, monitor = menuBarSystemMonitor] in
            var nextPowerSample = Date.distantPast
            var nextAlertCheck = Date.distantPast
            while !Task.isCancelled {
                let now = Date()
                let intervalSeconds = max(1, MenuBarRefreshInterval.load().rawValue)
                let lineOptions = MenuBarLineOption.savedSelection()
                let numberOptions = MenuBarNumberOption.savedSelection()
                let wantsBackgroundAlerts = DashboardNotificationManager.shared.isEnabled && now >= nextAlertCheck
                let includePower = wantsBackgroundAlerts || ((lineOptions.contains(where: \.requiresPowerSample)
                    || numberOptions.contains(where: { $0 == .battery || $0 == .power || $0 == .mouseBattery })) && now >= nextPowerSample)
                let (usage, snapshot) = await Task.detached(priority: .utility) {
                    (monitor.sampleMenuBarUsage(lines: lineOptions, numbers: numberOptions), includePower ? monitor.sampleMenuBar() : nil)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.menuBarUsageMetrics = usage
                if let snapshot {
                    self.menuBarSystemSnapshot = snapshot
                    nextPowerSample = now.addingTimeInterval(5)
                    if wantsBackgroundAlerts {
                        nextAlertCheck = now.addingTimeInterval(60)
                        DashboardNotificationManager.shared.evaluatePower(snapshot.powerFlow)
                    }
                }
                self.updateStatusItem()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    private func observeDisplaySleep() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displaysSleeping = true
                    self.loadedPanel?.closePanel()
                    self.menuBarSamplingTask?.cancel()
                    self.menuBarSamplingTask = nil
                    IntegratedHotCornerController.shared.stopPolling()
                    AutoBrightnessController.shared.setSleeping(true)
                }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, DisplaySafetyPolicy.physicalScreensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displaysSleeping = false
                    self.startMenuBarSampling()
                    IntegratedHotCornerController.shared.sync()
                    AutoBrightnessController.shared.setSleeping(false)
                }
            })
        }
    }

    private func restartMenuBarSampling() {
        menuBarSamplingTask?.cancel()
        menuBarSamplingTask = nil
        startMenuBarSampling()
    }

    func showPopover() {
        guard let button = statusItem.button, !panel.isVisible else { return }
        if panel.show(relativeTo: button) {
            contentController.setPopoverVisible(true)
        }
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

    func showDisplayConsolePage() {
        contentController.showDisplayConsolePage()
    }

    func showToolboxPage() {
        contentController.showToolboxPage()
    }

    func showRunningAppsPage(ports: Bool = false) {
        contentController.showRunningAppsPage(ports: ports)
    }

    func showDiskCleanupPage() {
        contentController.showDiskCleanupPage()
    }

    func showMagpiePage(_ page: MagpieServerPage) {
        contentController.showMagpiePage(page)
        showPopover()
    }

    @objc private func openMagpieRouting() { showMagpiePage(.routing) }
    @objc private func openMagpieUsage() { showMagpiePage(.usage) }
    @objc private func openDisplayConsoleFromMenu() {
        contentController.showDisplayConsolePage()
        showPopover()
    }
    @objc private func openMemoryCleanupFromMenu() {
        contentController.showStorageCleanupPage()
        showPopover()
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
        } else if panel.show(relativeTo: button) {
            contentController.setPopoverVisible(true)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let lineOptions = MenuBarLineOption.savedSelection()
        let usage: [Double?] = lineOptions.map { option in
            switch option {
            case .battery: return menuBarSystemSnapshot?.powerFlow.batteryLevel
            case .power: return menuBarSystemSnapshot?.powerFlow.systemWatts.map { $0 / 100 }
            case .mouseBattery: return menuBarSystemSnapshot?.metrics.first(where: { $0.kind == .mouseBattery })?.value
            case .cpuTemp:
                return menuBarUsageMetrics.first(where: { $0.kind == .thermal })?.value
            case .cpu, .gpu, .memory, .disk:
                return menuBarUsageMetrics.first(where: { $0.kind.rawValue == option.rawValue })?.value
            }
        }
        let iconSignature = zip(lineOptions, usage).map { option, value in
            guard let value, value.isFinite else { return option.rawValue + ":unknown" }
            let fraction = min(max(value, 0), 1)
            let band = option.isBattery ? (fraction <= 0.2 ? 0 : (fraction <= 0.5 ? 1 : 2)) : (fraction >= 0.8 ? 0 : (fraction >= 0.5 ? 1 : 2))
            return "\(option.rawValue):\(Int((fraction * 40).rounded())):\(band)"
        }.joined(separator: "|")
        if lastIconSignature != iconSignature {
        lastIconSignature = iconSignature
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { bounds in
            for (index, value) in usage.enumerated() {
                let track = NSRect(x: 0, y: 13 - CGFloat(index) * 6, width: bounds.width, height: 3)
                NSColor.systemGray.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                guard let value, value.isFinite else { continue }
                let fraction = min(max(value, 0), 1)
                guard fraction > 0 else { continue }
                let color: NSColor
                if lineOptions[index].isBattery {
                    color = fraction <= 0.2 ? .systemRed : (fraction <= 0.5 ? .systemYellow : .systemGreen)
                } else {
                    color = fraction >= 0.8 ? .systemRed : (fraction >= 0.5 ? .systemYellow : .systemGreen)
                }
                color.setFill()
                let fill = NSRect(x: track.minX, y: track.minY, width: max(1, track.width * fraction), height: track.height)
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = false
        button.image = image
        }
        let selected = MenuBarNumberOption.savedSelection()
        var values: [String] = []
        for option in MenuBarNumberOption.allCases where selected.contains(option) {
            switch option {
            case .cpu:
                let raw = menuBarUsageMetrics.first(where: { $0.kind == .cpu })?.rawString
                values.append(raw ?? "--")
            case .memory:
                let raw = menuBarUsageMetrics.first(where: { $0.kind == .memory })?.rawString
                values.append(raw ?? "--")
            case .cpuTemp:
                let raw = menuBarUsageMetrics.first(where: { $0.kind == .thermal })?.rawString
                values.append(raw ?? "--")
            case .network:
                let raw = menuBarUsageMetrics.first(where: { $0.kind == .network })?.rawString
                values.append(raw ?? "--")
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
            if statusItem.length != NSStatusItem.squareLength { statusItem.length = NSStatusItem.squareLength }
            if !button.title.isEmpty { button.title = "" }
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
        } else {
            if statusItem.length != NSStatusItem.variableLength { statusItem.length = NSStatusItem.variableLength }
            let title = " " + values.joined(separator: "  ")
            if button.title != title { button.title = title }
            if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading }
        }

        var tooltip = AppBrand.displayName
        tooltip += "\n" + zip(lineOptions, usage).map { option, value in
            option.title + " " + (option == .power ? watts(menuBarSystemSnapshot?.powerFlow.systemWatts) : percent(value))
        }.joined(separator: " · ")
        if keepAwake.isEnabled {
            tooltip += " · 屏幕常亮"
        }
        if screenClean.isActive {
            tooltip += " · 擦屏模式"
        }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        if panel.isVisible {
            panel.closePanel()
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        addStatusMenuItem(menu, title: "显示器控制台", symbol: "display.2",
            action: #selector(openDisplayConsoleFromMenu))
        addStatusMenuItem(menu, title: "内存透视与清理", symbol: "memorychip",
            action: #selector(openMemoryCleanupFromMenu))
        addStatusMenuItem(menu, title: "模型路由 · 服务器", symbol: "arrow.triangle.branch",
            action: #selector(openMagpieRouting))
        addStatusMenuItem(menu, title: "用量概览 · 服务器", symbol: "chart.bar.xaxis",
            action: #selector(openMagpieUsage))
        menu.addItem(.separator())

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

    @objc private func openSettingsFromStatusMenu() {
        showSettings()
    }

    @objc private func quitFromStatusMenu() {
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
            let controller = SettingsWindowController(contentController: AppSettingsViewController())
            controller.onSettingsSaved = { [weak self] in
                self?.keepAwake.start()
                IntegratedHotCornerController.shared.sync()
                self?.restartMenuBarSampling()
                self?.updateStatusItem()
                self?.loadedContentController?.refreshLayout()
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
    var onPreferredSizeChanged: ((NSSize) -> Void)?
    var onStatusBarNeedsUpdate: (() -> Void)?
    weak var keepAwakeController: KeepAwakeController?
    weak var screenCleanController: ScreenCleanModeController?

    private let magpieDashboard = MagpieDashboardController()
    private var viewWidthConstraint: NSLayoutConstraint?
    private var isServerPage: Bool { selectedPage == 5 || selectedPage == 6 }

    private let rootStack = NSStackView()
    private let scrollView = NSScrollView()
    private let accountStack = NSStackView()
    private let refreshButton = NSButton()
    private let refreshSpin = NSProgressIndicator()
    private let headerTitleLabel = NSTextField(labelWithString: "系统状态")
    private let updatedLabel = NSTextField(labelWithString: "尚未刷新")
    private let pageControl = NSSegmentedControl(labels: ["状态", "运行", "电源", "清理"], trackingMode: .selectOne, target: nil, action: nil)
    private var pageControlWidthConstraint: NSLayoutConstraint?
    private(set) var selectedPage = 1
    private var segmentPages = [1, 2, 3, 4, 8, 7]
    private let systemMonitor = SystemStatusMonitor()
    private let runningAppsMonitor = RunningAppsMonitor()
    private var systemSamplingTask: Task<Void, Never>?
    private var appsSamplingTask: Task<Void, Never>?
    private var memoryCleanupSamplingTask: Task<Void, Never>?
    private var memorySampleTask: Task<Void, Never>?
    private var portScanTask: Task<Void, Never>?
    private var runningApps: [RunningApp] = []
    private var listeningPorts: [ListeningPortItem] = []
    private var portTargets: [String: ListeningPortProcessController.Target] = [:]
    private var portTerminationTask: Task<Void, Never>?
    private var runningSubmode: RunningPageSubmode = .apps
    private var runningSearchQuery: String = ""
    private var runningToolbar: RunningAppsToolbarView?
    private var runningRows: [RunningAppIdentity: RunningAppRowView] = [:]
    private var portRows: [String: ListeningPortRowView] = [:]

    private var cleanupMode: CleanupPageMode = .memory
    private var memoryCleanupDashboard: MemoryCleanupDashboardView?
    private var cleanupDashboard: StorageCleanupDashboardView?
    var makeDisplayConsole: () -> DisplayConsoleDashboardView = { DisplayConsoleDashboardView() }
    private var displayConsoleDashboard: DisplayConsoleDashboardView?
    private var toolboxDashboard: QuickToolboxDashboardView?
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
        let widthConstraint = view.widthAnchor.constraint(equalToConstant: Tokens.popoverSize.width)
        viewWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])

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
        addChild(magpieDashboard)
        magpieDashboard.view.isHidden = true
        rootStack.addArrangedSubview(magpieDashboard.view)

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
        displayConsoleDashboard?.isPresented = isPopoverVisible && selectedPage == 8
        stopSystemSampling()
        stopAppsSampling()
        stopMemoryCleanupSampling()
        portScanTask?.cancel()
        portScanTask = nil
        stopCleanupScanning()
        systemCards.removeAll()
        powerDashboard = nil
        memoryCleanupDashboard = nil
        cleanupDashboard = nil
        toolboxDashboard = nil
        runningToolbar = nil
        runningRows.removeAll()
        portRows.removeAll()
        accountStack.arrangedSubviews.forEach {
            accountStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        scrollView.isHidden = isServerPage
        magpieDashboard.view.isHidden = !isServerPage
        if !isServerPage { magpieDashboard.suspend() }
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
        case 7:
            renderToolboxPage()
        case 8:
            renderDisplayConsolePage()
        case 5, 6:
            if isPopoverVisible { magpieDashboard.show(page: selectedPage == 5 ? .routing : .usage) }
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
        if isServerPage {
            let screen = view.window?.screen ?? NSScreen.main
            let available = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 840)
            applyPreferredSize(NSSize(width: min(1240, available.width - 16), height: min(850, available.height - 16)))
            return
        }
        applyPreferredSize(NSSize(width: Tokens.popoverSize.width, height: viewHeightConstraint?.constant ?? Tokens.popoverSize.height))
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
        let fittedHeight = Tokens.headerHeight + contentHeight + 2
        let desired = min(Tokens.popoverSize.height, selectedPage == 8 ? fittedHeight : max(260, fittedHeight))
        applyPreferredSize(NSSize(width: Tokens.popoverSize.width, height: desired))
    }

    private func applyPreferredSize(_ size: NSSize) {
        viewWidthConstraint?.constant = size.width
        viewHeightConstraint?.constant = size.height
        preferredContentSize = size
        pageControlWidthConstraint?.constant = isServerPage ? min(520, size.width - 110) : 292
        onPreferredSizeChanged?(size)
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
            SystemMetric(kind: .thermal, title: "散热", detail: "正在读取…", value: nil, accessibilityHelp: "处理器温度与风扇转速"),
            SystemMetric(kind: .network, title: "网络", detail: "正在采样…", value: nil, accessibilityHelp: "当前网络上传与下载速率"),
            SystemMetric(kind: .battery, title: "电池", detail: "正在读取…", value: nil, accessibilityHelp: "电池电量、充电状态与健康信息"),
            SystemMetric(kind: .mouseBattery, title: "鼠标", detail: "正在读取…", value: nil, accessibilityHelp: "已连接鼠标的剩余电量")
        ]
        for metric in placeholders {
            let card = SystemMetricCard(metric: metric)
            card.onTap = { [weak self] kind in
                self?.handleMetricCardClick(kind)
            }
            systemCards[metric.kind] = card
            accountStack.addArrangedSubview(card)
        }
    }

    func handleMetricCardClick(_ kind: SystemMetric.Kind) {
        switch kind {
        case .cpu, .gpu:
            jumpToPage(2)
        case .memory:
            cleanupMode = .memory
            jumpToPage(4)
        case .disk:
            cleanupMode = .disk
            jumpToPage(4)
        case .power, .battery, .thermal, .mouseBattery:
            jumpToPage(3)
        case .network:
            jumpToPage(7)
        }
    }

    private func jumpToPage(_ page: Int) {
        loadViewIfNeeded()
        if !segmentPages.contains(page) {
            UserDefaults.standard.set(true, forKey: "dashboardPageVisible\(page)")
            configureVisiblePages()
        }
        selectedPage = page
        pageControl.selectedSegment = segmentPages.firstIndex(of: page) ?? 0
        renderSelectedPage()
    }

    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        displayConsoleDashboard?.isPresented = visible && selectedPage == 8
        powerDashboard?.setAnimationsActive(visible && selectedPage == 3)
        if visible && isServerPage { magpieDashboard.show(page: selectedPage == 5 ? .routing : .usage) }
        else { magpieDashboard.suspend() }
        updateSystemSamplingState()
        updateAppsSamplingState()
        updateMemoryCleanupSamplingState()
        if visible {
            toolboxDashboard?.refreshState()
            if selectedPage == 8 { displayConsoleDashboard?.refreshAll() }
        }
    }

    func showSystemStatusPage() {
        jumpToPage(1)
    }

    func showPowerFlowPage() {
        jumpToPage(3)
    }

    func showStorageCleanupPage() {
        jumpToPage(4)
    }

    func showDisplayConsolePage() {
        jumpToPage(8)
    }

    func showToolboxPage() {
        jumpToPage(7)
    }

    func showRunningAppsPage(ports: Bool = false) {
        runningSubmode = ports ? .ports : .apps
        jumpToPage(2)
        if ports { triggerPortScan() }
    }

    func showDiskCleanupPage() {
        cleanupMode = .disk
        jumpToPage(4)
    }

    private func renderPowerFlowPage() {
        let dashboard = PowerFlowDashboardView()
        powerDashboard = dashboard
        dashboard.setAnimationsActive(isPopoverVisible)
        dashboard.onHeightChanged = { [weak self] in
            self?.updatePreferredHeight()
        }
        dashboard.onRefreshNearbyDevices = { [weak self] in
            guard let controller = self else { return }
            SystemStatusMonitor.refreshNearbyDevices { [weak controller] _ in
                let target = controller
                Task { @MainActor in
                    guard let target, target.selectedPage == 3 else { return }
                    let monitor = target.systemMonitor
                    let snap = await Task.detached(priority: .userInitiated) {
                        monitor.sample(includeBatteryPackDetail: true)
                    }.value
                    guard target.selectedPage == 3 else { return }
                    target.applySystemSnapshot(snap)
                }
            }
        }
        accountStack.addArrangedSubview(dashboard)
    }

    func showMagpiePage(_ page: MagpieServerPage) {
        loadViewIfNeeded()
        selectedPage = page == .routing ? 5 : 6
        if !segmentPages.contains(selectedPage) {
            UserDefaults.standard.set(true, forKey: "dashboardPageVisible\(selectedPage)")
            configureVisiblePages()
        }
        pageControl.selectedSegment = segmentPages.firstIndex(of: selectedPage) ?? 0
        renderSelectedPage()
        updatePreferredHeight()
    }

    private func renderStorageCleanupPage() {
        let modeBar = NSSegmentedControl(
            labels: CleanupPageMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(cleanupModeChanged(_:))
        )
        modeBar.controlSize = .small
        modeBar.segmentStyle = .rounded
        modeBar.segmentDistribution = .fillEqually
        modeBar.selectedSegment = CleanupPageMode.allCases.firstIndex(of: cleanupMode) ?? 0
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        modeBar.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
        accountStack.addArrangedSubview(modeBar)

        switch cleanupMode {
        case .memory:
            let memView = MemoryCleanupDashboardView()
            memoryCleanupDashboard = memView
            memView.onHeightChanged = { [weak self] in self?.updatePreferredHeight() }
            memView.onRefreshRequested = { [weak self] in self?.sampleMemoryCleanupOnce() }
            memView.onSmartClean = { [weak self] selectedIDs in
                self?.performSmartMemoryClean(selectedIDs: selectedIDs)
            }
            memView.onTerminateSingleApp = { [weak self] app in
                self?.gracefullyQuitFromMemoryView(app)
            }
            accountStack.addArrangedSubview(memView)
            sampleMemoryCleanupOnce()
            updateMemoryCleanupSamplingState()
        case .disk:
            let dashboard = StorageCleanupDashboardView()
            cleanupDashboard = dashboard
            dashboard.onScan = { [weak self] in self?.scanStorageCleanup() }
            dashboard.onClean = { [weak self] items in
                self?.confirmStorageCleanup(items: items)
            }
            dashboard.onHeightChanged = { [weak self] in self?.updatePreferredHeight() }
            accountStack.addArrangedSubview(dashboard)
            scanStorageCleanup()
        }
    }

    @objc private func cleanupModeChanged(_ sender: NSSegmentedControl) {
        let idx = min(max(0, sender.selectedSegment), CleanupPageMode.allCases.count - 1)
        cleanupMode = CleanupPageMode.allCases[idx]
        renderSelectedPage()
    }

    private func sampleMemoryCleanupOnce() {
        guard memorySampleTask == nil, selectedPage == 4, cleanupMode == .memory, let memView = memoryCleanupDashboard else { return }
        let candidates = runningAppsMonitor.candidates()
        let monitor = systemMonitor
        let appsMonitor = runningAppsMonitor
        memorySampleTask = Task { [weak self, weak memView] in
            defer { self?.memorySampleTask = nil }
            let (mem, apps) = await Task.detached(priority: .userInitiated) {
                (monitor.sampleDetailedMemory(), appsMonitor.sample(candidates))
            }.value
            guard let self, self.selectedPage == 4, self.cleanupMode == .memory,
                  self.memoryCleanupDashboard === memView else { return }
            self.runningApps = apps
            memView?.update(memory: mem, apps: apps)
        }
    }

    private func updateMemoryCleanupSamplingState() {
        guard isPopoverVisible, selectedPage == 4, cleanupMode == .memory else {
            stopMemoryCleanupSampling()
            return
        }
        guard memoryCleanupSamplingTask == nil else { return }
        memoryCleanupSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isPopoverVisible, self.selectedPage == 4, self.cleanupMode == .memory else { return }
                self.sampleMemoryCleanupOnce()
            }
        }
    }

    private func stopMemoryCleanupSampling() {
        memoryCleanupSamplingTask?.cancel()
        memoryCleanupSamplingTask = nil
    }

    private func performSmartMemoryClean(selectedIDs: [RunningAppIdentity]) {
        guard let memView = memoryCleanupDashboard else { return }
        memView.setCleaning(true)
        let beforeMem = systemMonitor.sampleDetailedMemory()?.availableBytes
        let requestedIDs = Array(Set(selectedIDs))
        let acceptedIDs = requestedIDs.filter { runningAppsMonitor.terminateGracefully($0) == .terminated }
        SafeMemoryOptimizer.releaseUserSpaceCaches()
        Task { [weak self, weak memView] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self else { return }
            SafeMemoryOptimizer.releaseUserSpaceCaches()
            let candidates = self.runningAppsMonitor.candidates()
            let monitor = self.systemMonitor
            let appsMonitor = self.runningAppsMonitor
            let (afterSnap, freshApps, closedAppsCount) = await Task.detached(priority: .userInitiated) {
                (monitor.sampleDetailedMemory(), appsMonitor.sample(candidates), acceptedIDs.filter { appsMonitor.isIdentityRunning($0) == false }.count)
            }.value
            memView?.setCleaning(false)
            memView?.update(memory: afterSnap, apps: freshApps)
            memView?.showComparisonResult(
                beforeAvailable: beforeMem,
                afterAvailable: afterSnap?.availableBytes,
                closedCount: closedAppsCount,
                requestedCount: requestedIDs.count
            )
        }
    }

    private func gracefullyQuitFromMemoryView(_ app: RunningApp) {
        let beforeMem = systemMonitor.sampleDetailedMemory()?.availableBytes
        let res = runningAppsMonitor.terminateGracefully(app.identity)
        guard res == .terminated else {
            showActionError("未能退出 \(app.localizedName)（可能有未保存文档等待确认）")
            return
        }
        memoryCleanupDashboard?.setCleaning(true)
        Task { [weak self, weak memView = memoryCleanupDashboard] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, let memView else { return }
            let candidates = self.runningAppsMonitor.candidates()
            let monitor = self.systemMonitor
            let appsMonitor = self.runningAppsMonitor
            let (afterSnap, freshApps, didExit) = await Task.detached(priority: .userInitiated) {
                (monitor.sampleDetailedMemory(), appsMonitor.sample(candidates), appsMonitor.isIdentityRunning(app.identity) == false)
            }.value
            memView.setCleaning(false)
            memView.update(memory: afterSnap, apps: freshApps)
            memView.showComparisonResult(
                beforeAvailable: beforeMem,
                afterAvailable: afterSnap?.availableBytes,
                closedCount: didExit ? 1 : 0,
                requestedCount: 1
            )
        }
    }

    private func renderDisplayConsolePage() {
        let console = displayConsoleDashboard ?? makeDisplayConsole()
        displayConsoleDashboard = console
        console.isPresented = isPopoverVisible
        console.onHeightChanged = { [weak self] in
            guard let self, self.selectedPage == 8 else { return }
            self.updatePreferredHeight()
        }
        accountStack.addArrangedSubview(console)
        console.refreshAll()
    }

    private func renderToolboxPage() {
        let toolbox = QuickToolboxDashboardView()
        toolboxDashboard = toolbox
        toolbox.onHeightChanged = { [weak self] in self?.updatePreferredHeight() }
        toolbox.keepAwakeSummaryProvider = { [weak self] in
            guard let ka = self?.keepAwakeController else { return (0, "跟随系统默认休眠设置") }
            if let mins = ka.activeTimedRemainingMinutes {
                let idx = mins <= 30 ? 1 : (mins <= 60 ? 2 : 3)
                return (idx, ka.statusSummary ?? "定时常亮中")
            }
            if ka.isEnabled {
                return (4, "始终保持屏幕常亮（已阻止自动休眠）")
            }
            return (0, "跟随系统默认休眠设置")
        }
        toolbox.onSelectKeepAwakeMode = { [weak self] mode in
            guard let ka = self?.keepAwakeController else { return }
            if let minutes = mode {
                if minutes == 0 {
                    ka.isEnabled = true
                } else {
                    ka.startTimed(minutes: minutes)
                }
            } else {
                ka.isEnabled = false
                ka.cancelTimedAwake()
            }
            self?.onStatusBarNeedsUpdate?()
        }
        toolbox.onTogglePresentationMode = { [weak self] in
            guard let ka = self?.keepAwakeController else { return false }
            let active = PresentationModeController.shared.toggle(keepAwake: ka)
            self?.onStatusBarNeedsUpdate?()
            return active
        }
        toolbox.onEnterScreenClean = { [weak self] in
            guard let self, let clean = self.screenCleanController else { return }
            (self.view.window as? AnchoredStatusPanel)?.closePanel()
            self.setPopoverVisible(false)
            self.keepAwakeController?.beginTemporaryHold()
            clean.enter()
            self.onStatusBarNeedsUpdate?()
        }
        accountStack.addArrangedSubview(toolbox)
        toolbox.refreshState()
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
        let toolbar = runningToolbar ?? RunningAppsToolbarView(
            mode: runningAppsSortMode,
            submode: runningSubmode,
            query: runningSearchQuery
        )
        runningToolbar = toolbar
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
        toolbar.onChange = { [weak self] mode in
            guard let self else { return }
            self.runningAppsSortMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "runningAppsSortMode")
            self.rebuildRunningListItems()
        }
        toolbar.onSubmodeChange = { [weak self] sub in
            guard let self else { return }
            self.runningSubmode = sub
            self.updateAppsSamplingState()
            if sub == .ports { self.triggerPortScan() }
            self.rebuildRunningListItems()
        }
        toolbar.onSearchChange = { [weak self] q in
            guard let self else { return }
            self.runningSearchQuery = q
            self.rebuildRunningListItems()
        }
        toolbar.onRefreshPorts = { [weak self] in
            self?.triggerPortScan()
        }
        accountStack.addArrangedSubview(toolbar)
        if runningSubmode == .ports { triggerPortScan() }
        rebuildRunningListItems()
    }

    private func rebuildRunningListItems() {
        guard selectedPage == 2 else { return }
        let q = runningSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if runningSubmode == .ports {
            let filtered = listeningPorts.filter { item in
                guard !q.isEmpty else { return true }
                return "\(item.port)".contains(q)
                    || item.processName.lowercased().contains(q)
                    || "\(item.pid)".contains(q)
            }
            runningToolbar?.updateSummary("监听 \(filtered.count) 个端口", submode: .ports, mode: runningAppsSortMode)
            if filtered.isEmpty {
                replaceRunningContent(with: [messageView(
                    icon: "network",
                    text: portScanTask != nil ? "正在扫描本机监听 TCP 端口…" : "没有匹配的监听端口",
                    color: .secondaryLabelColor
                )])
            } else {
                var rows: [NSView] = []
                let identities = Set(listeningPorts.map(\.id))
                portRows = portRows.filter { identities.contains($0.key) }
                for item in filtered {
                    let row: ListeningPortRowView
                    if let existing = portRows[item.id] {
                        row = existing
                        row.update(item: item)
                    } else {
                        row = ListeningPortRowView(item: item)
                        row.translatesAutoresizingMaskIntoConstraints = false
                        row.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
                        row.heightAnchor.constraint(equalToConstant: 48).isActive = true
                        portRows[item.id] = row
                    }
                    row.onTerminatePID = { [weak self] target in
                        self?.confirmKillPortProcess(target)
                    }
                    rows.append(row)
                }
                replaceRunningContent(with: rows)
            }
            updatePreferredHeight()
            return
        }

        if runningApps.isEmpty {
            runningToolbar?.updateSummary("采样中…", submode: .apps, mode: runningAppsSortMode)
            replaceRunningContent(with: [messageView(icon: "arrow.triangle.2.circlepath", text: "正在读取运行中应用…", color: .secondaryLabelColor)])
            updatePreferredHeight()
            return
        }
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
        let filteredApps = sortedApps.filter { app in
            guard !q.isEmpty else { return true }
            return app.localizedName.lowercased().contains(q)
                || (app.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
        let totalMem = filteredApps.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
        let memStr = ByteCountFormatter.string(fromByteCount: Int64(min(totalMem, UInt64(Int64.max))), countStyle: .memory)
        runningToolbar?.updateSummary("\(filteredApps.count) 个 · \(memStr)", submode: .apps, mode: runningAppsSortMode)

        let identities = Set(runningApps.map(\.identity))
        runningRows = runningRows.filter { identities.contains($0.key) }
        var rows: [NSView] = []
        for app in filteredApps {
            let row: RunningAppRowView
            if let existing = runningRows[app.identity] {
                row = existing
                row.update(app: app)
            } else {
                row = RunningAppRowView(app: app)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalToConstant: Tokens.cardWidth).isActive = true
                row.heightAnchor.constraint(equalToConstant: 52).isActive = true
                runningRows[app.identity] = row
            }
            row.onKill = { [weak self] in self?.confirmForceQuit(app) }
            row.onGracefulQuit = { [weak self] in
                guard let self else { return }
                if self.runningAppsMonitor.terminateGracefully(app.identity) == .terminated {
                    self.runningApps.removeAll { $0.identity == app.identity }
                    self.rebuildRunningListItems()
                }
            }
            rows.append(row)
        }
        if rows.isEmpty {
            rows.append(messageView(icon: "magnifyingglass", text: "没有匹配的应用", color: .secondaryLabelColor))
        }
        replaceRunningContent(with: rows)
        updatePreferredHeight()
    }

    private func replaceRunningContent(with rows: [NSView]) {
        let current = accountStack.arrangedSubviews.filter { $0 !== runningToolbar }
        guard current.count != rows.count || !zip(current, rows).allSatisfy({ $0 === $1 }) else { return }
        for row in current {
            accountStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows.forEach { accountStack.addArrangedSubview($0) }
    }

    private func triggerPortScan() {
        portScanTask?.cancel()
        portScanTask = Task { [weak self] in
            let targets = await Task.detached(priority: .userInitiated) {
                ListeningPortProcessController.scan()
            }.value
            guard !Task.isCancelled, let self, self.selectedPage == 2 else { return }
            self.portScanTask = nil
            self.listeningPorts = targets.map(\.item)
            self.portTargets = targets.reduce(into: [:]) { $0[$1.id] = $1 }
            if self.runningSubmode == .ports {
                self.rebuildRunningListItems()
            }
        }
    }

    private func updateAppsSamplingState() {
        guard isPopoverVisible, selectedPage == 2, runningSubmode == .apps else {
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
        rebuildRunningListItems()
    }

    private func confirmKillPortProcess(_ item: ListeningPortItem) {
        guard portTerminationTask == nil else { return }
        guard let target = portTargets[item.id] else {
            showActionError("进程快照已失效，请刷新端口列表后重试")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "结束监听端口 :\(item.port) 的进程？"
        alert.informativeText = "将向 \(item.processName)（PID \(item.pid)）发送终止信号以释放端口。"
        alert.addButton(withTitle: "释放端口")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        portTerminationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ListeningPortProcessController.terminateSafely(target)
            }.value
            guard let self else { return }
            self.portTerminationTask = nil
            switch result {
            case .success:
                self.updatedLabel.stringValue = "已发送退出请求，正在重新检查端口"
                try? await Task.sleep(for: .milliseconds(500))
                if self.selectedPage == 2 { self.triggerPortScan() }
            case .failure(let error):
                self.showActionError(error.localizedDescription)
            }
        }
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
        if let directory = ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            view.layoutSubtreeIfNeeded()
            let captureTargets: [(String, NSView)] = [("viewport", view), ("content", accountStack)]
            for (name, target) in captureTargets {
                guard target.bounds.width > 0, target.bounds.height > 0,
                      let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
                target.cacheDisplay(in: target.bounds, to: bitmap)
                if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    target.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill(using: .destinationOver)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: destination.appendingPathComponent("page-\(selectedPage)-\(name).png"))
                }
            }
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
        pageControl.toolTip = "切换状态、运行、电源、清理、屏幕、工具、路由和用量"

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

        let pageWidth = pageControl.widthAnchor.constraint(equalToConstant: 338)
        pageControlWidthConstraint = pageWidth
        NSLayoutConstraint.activate([
            pageControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Tokens.padding),
            pageControl.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -6),
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
            updatedLabel.stringValue = "应用与监听端口猎手"
        case 3:
            headerTitleLabel.stringValue = "电源流向"
            updatedLabel.stringValue = "Mac 每 1 秒 · 设备每 5 分钟"
        case 7:
            headerTitleLabel.stringValue = "快捷工具箱"
            updatedLabel.stringValue = "音频守卫 · 演示净空 · 网络诊断"
        case 8:
            headerTitleLabel.stringValue = "屏幕"
            updatedLabel.stringValue = ""
        case 5, 6:
            headerTitleLabel.stringValue = "服务器模型"
            updatedLabel.stringValue = "Magpie · 服务器实时数据"
        default:
            headerTitleLabel.stringValue = cleanupMode == .memory ? "内存深度透视与清理" : "清理储存空间"
            updatedLabel.stringValue = cleanupMode == .memory ? "四维内存拆解 · 无损安全释放" : "按需扫描 · 移入废纸篓"
        }
    }

    private func configureVisiblePages() {
        let defaults = UserDefaults.standard
        let orderMode = defaults.string(forKey: "dashboardPageOrder") ?? "default"
        let baseOrder: [Int]
        switch orderMode {
        case "powerFirst": baseOrder = [3, 1, 2, 4, 8, 7]
        case "statusFirst": baseOrder = [1, 3, 2, 4, 8, 7]
        case "cleanFirst": baseOrder = [4, 1, 2, 3, 8, 7]
        case "displayFirst": baseOrder = [8, 1, 3, 4, 2, 7]
        case "toolsFirst": baseOrder = [7, 8, 1, 4, 3, 2]
        default: baseOrder = [1, 2, 3, 4, 8, 7]
        }
        segmentPages = (baseOrder + [5, 6]).filter { page in
            let key = "dashboardPageVisible\(page)"
            return defaults.object(forKey: key) as? Bool ?? true
        }
        if segmentPages.isEmpty { segmentPages = [1] }
        if !segmentPages.contains(selectedPage) { selectedPage = segmentPages[0] }
        let labels = [1: "状态", 2: "运行", 3: "电源", 4: "清理", 8: "屏幕", 7: "工具", 5: "路由", 6: "用量"]
        pageControl.segmentCount = segmentPages.count
        pageControl.font = .systemFont(ofSize: segmentPages.count >= 7 ? 10.5 : 11.5, weight: .semibold)
        pageControlWidthConstraint?.constant = min(
            340,
            max(128, CGFloat(segmentPages.count) * 56)
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
        let pageItems: [(String, Int)] = [
            ("系统状态", 1),
            ("运行与端口", 2),
            ("电源流向", 3),
            ("内存与磁盘清理", 4),
            ("显示器控制台", 8),
            ("快捷工具箱", 7),
            ("模型路由", 5),
            ("用量概览", 6)
        ]
        for (title, p) in pageItems {
            let item = NSMenuItem(title: title, action: #selector(jumpPageFromMoreMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = p
            item.state = (selectedPage == p) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
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

    @objc private func jumpPageFromMoreMenu(_ sender: NSMenuItem) {
        jumpToPage(sender.tag)
    }

    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }
}

@MainActor
final class SystemMetricCard: LiquidGlassCardView {
    var onTap: ((SystemMetric.Kind) -> Void)?
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
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
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

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onTap?(kind)
        }
    }

    func update(_ metric: SystemMetric) {
        kind = metric.kind
        currentMetric = metric
        if metric.kind == .disk {
            valueLabel.stringValue = metric.detail.components(separatedBy: "（").first ?? metric.detail
        } else {
            valueLabel.stringValue = metric.detail
        }
        valueLabel.toolTip = metric.detail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: valueLabel.stringValue.count > 26 ? 12.5 : 15, weight: .semibold)
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
        case .thermal: return "thermometer.medium"
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
    private weak var trackingPopupMenu: NSMenu?
    private var anchorScreenRect: NSRect?
    private weak var anchorScreen: NSScreen?
    private var requestedSize = Tokens.popoverSize

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
        self.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(popupOpening(_:)), name: NSPopUpButton.willPopUpNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popupClosed(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func popupOpening(_ notification: Notification) {
        let button = notification.object as? NSPopUpButton ?? (notification.object as? NSPopUpButtonCell)?.controlView as? NSPopUpButton
        guard let button, button.window === self else { return }
        trackingPopupMenu = button.menu
    }

    @objc private func popupClosed(_ notification: Notification) {
        if notification.object as? NSMenu === trackingPopupMenu { trackingPopupMenu = nil }
    }

    var dismissesOnOutsideInteraction: Bool {
        !keepsOpenForDebugCapture && trackingPopupMenu == nil && attachedSheet == nil
    }

    private func setupEventMonitors() {
        guard clickEventMonitor == nil else { return }
        clickEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.dismissesOnOutsideInteraction == true { self?.closePanel() }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.window !== self && event.window?.sheetParent !== self && self.dismissesOnOutsideInteraction { self.closePanel() }
            return event
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard self?.isVisible == true else { return event }
            if event.keyCode == 53 && self?.trackingPopupMenu == nil && self?.attachedSheet == nil { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidResignActive() {
        if dismissesOnOutsideInteraction { closePanel() }
    }

    func closePanel() {
        tearDownEventMonitors()
        trackingPopupMenu = nil
        if isVisible {
            close()
        }
        if let vc = contentViewController as? QuotaPopoverViewController {
            vc.setPopoverVisible(false)
        }
    }

    @discardableResult
    func show(relativeTo button: NSStatusBarButton) -> Bool {
        guard let window = button.window else { return false }
        let capturesOffscreen = ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DIR"] != nil
        let buttonRect = button.convert(button.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRect)
        guard let screen = screen(containing: buttonScreenRect, fallback: window.screen) else { return false }
        if !capturesOffscreen { setupEventMonitors() }
        anchorScreenRect = buttonScreenRect
        anchorScreen = screen
        let target = frameFor(anchor: buttonScreenRect, on: screen, size: requestedSize)
        setFrame(target, display: false)
        if capturesOffscreen {
            ignoresMouseEvents = true
            contentView?.layoutSubtreeIfNeeded()
        } else {
            makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func tearDownEventMonitors() {
        for monitor in [clickEventMonitor, localMouseMonitor, keyEventMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        clickEventMonitor = nil
        localMouseMonitor = nil
        keyEventMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func screen(containing rect: NSRect, fallback: NSScreen?) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? fallback
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func frameFor(anchor: NSRect, on screen: NSScreen, size requested: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let maxW = max(160, visible.width - 16)
        let maxH = max(120, visible.height - 16)
        let size = NSSize(width: max(160, min(requested.width, maxW)), height: max(120, min(requested.height, maxH)))
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

    func resizeContent(to size: NSSize) {
        requestedSize = size
        let target: NSRect
        if let anchorScreenRect, let anchorScreen {
            target = frameFor(anchor: anchorScreenRect, on: anchorScreen, size: size)
        } else {
            target = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
        guard abs(frame.width - target.width) > 1 || abs(frame.height - target.height) > 1 else { return }
        setFrame(target, display: true, animate: false)
    }

    override func cancelOperation(_ sender: Any?) {
        closePanel()
    }

    override func resignKey() {
        super.resignKey()
        if dismissesOnOutsideInteraction { closePanel() }
    }
}
