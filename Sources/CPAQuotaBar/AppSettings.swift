import AppKit
import ServiceManagement

@MainActor
final class AppSettingsViewController: NSViewController {
    var onSaved: (() -> Void)?

    private var launchAtLoginSwitch: NSSwitch!
    private var keepAwakeSwitch: NSSwitch!
    private var hotCornerSwitch: NSSwitch!
    private var notificationsSwitch: NSSwitch!
    private var refreshIntervalPopup: NSPopUpButton!
    private var menuBarNumberSwitches: [MenuBarNumberOption: NSSwitch] = [:]
    private var menuBarLinePopups: [NSPopUpButton] = []
    private var statusPageSwitch: NSSwitch!
    private var runningPageSwitch: NSSwitch!
    private var powerPageSwitch: NSSwitch!
    private var cleanupPageSwitch: NSSwitch!
    private var displaysPageSwitch: NSSwitch!
    private var toolboxPageSwitch: NSSwitch!
    private var modelPageSwitch: NSSwitch!
    private var usagePageSwitch: NSSwitch!
    private var pageOrderPopup: NSPopUpButton!
    private var generalPane: NSView!
    private var aboutPane: NSView!
    private var displayPane: NSView!
    private var saveButton: NSButton!
    private var tabControl: NSSegmentedControl!
    private let pageValidationLabel = NSTextField(wrappingLabelWithString: "至少保留一个页面。")
    private let notificationStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var presentationID = UUID()
    private let defaults: UserDefaults
    private let loginStatus: () -> SMAppService.Status
    private let applyLogin: (Bool) throws -> Void
    private var generalScroll: NSScrollView!

    private let pageOrderOptions: [(title: String, value: String)] = [
        ("默认顺序", "default"),
        ("电源优先", "powerFirst"),
        ("状态优先", "statusFirst"),
        ("清理优先", "cleanFirst"),
        ("屏幕优先", "displayFirst"),
        ("工具优先", "toolsFirst")
    ]

    init(defaults: UserDefaults = .standard,
         loginStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         applyLogin: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.defaults = defaults
        self.loginStatus = loginStatus
        self.applyLogin = applyLogin
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareForPresentation() {
        loadViewIfNeeded()
        reloadSettingsFromDefaults()
        presentationID = UUID()
        let id = presentationID
        notificationStatusLabel.stringValue = "正在读取系统通知权限…"
        DashboardNotificationManager.shared.authorizationDescription { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.presentationID == id else { return }
                self.notificationStatusLabel.stringValue = message
            }
        }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight))
        container.translatesAutoresizingMaskIntoConstraints = false

        tabControl = NSSegmentedControl(
            labels: ["通用", "显示", "关于"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(switchSettingsTab(_:))
        )
        tabControl.segmentStyle = .rounded
        tabControl.controlSize = .regular
        tabControl.segmentDistribution = .fillEqually
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabControl)

        let panes = NSView()
        panes.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panes)

        generalScroll = scrollable(makeGeneralPane())
        generalPane = generalScroll
        displayPane = scrollable(makeDisplayPane())
        aboutPane = makeAboutPane()
        pinPane(generalPane, to: panes)
        pinPane(displayPane, to: panes)
        displayPane.isHidden = true
        pinPane(aboutPane, to: panes)
        aboutPane.isHidden = true

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerSeparator)

        let cancelButton = makeFooterButton(title: "取消", action: #selector(cancel))
        saveButton = makeFooterButton(title: "保存", action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.identifier = NSUserInterfaceItemIdentifier("settings.save")
        cancelButton.keyEquivalent = "\u{1b}"
        container.addSubview(cancelButton)
        container.addSubview(saveButton)

        // 内容视图偏好的默认尺寸：优先级低于窗口拖拽缩放，但高于 fittingSize 的压缩，
        // 防止窗口按内容最小高度收缩。
        let preferredWidth = container.widthAnchor.constraint(equalToConstant: SettingsLayout.windowWidth)
        let preferredHeight = container.heightAnchor.constraint(equalToConstant: SettingsLayout.windowHeight)
        preferredWidth.priority = NSLayoutConstraint.Priority(490)
        preferredHeight.priority = NSLayoutConstraint.Priority(490)

        NSLayoutConstraint.activate([
            preferredWidth,
            preferredHeight,
            tabControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            tabControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            tabControl.widthAnchor.constraint(equalToConstant: 252),
            panes.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            panes.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            panes.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 16),
            panes.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -12),
            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footerSeparator.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])

        let host = NSView(frame: container.bounds)
        host.wantsLayer = true
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            background = glass
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            background = effect
        }
        pinPane(background, to: host)
        pinPane(container, to: host)
        view = host
        preferredContentSize = NSSize(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        if let segment = ProcessInfo.processInfo.environment["SETTINGS_CAPTURE_SEGMENT"].flatMap(Int.init) {
            tabControl.selectedSegment = segment
            switchSettingsTab(tabControl)
        }
    }

    private func reloadSettingsFromDefaults() {
        guard isViewLoaded,
              let launchAtLoginSwitch,
              let keepAwakeSwitch,
              let hotCornerSwitch,
              let notificationsSwitch,
              let refreshIntervalPopup,
              let statusPageSwitch,
              let runningPageSwitch,
              let powerPageSwitch,
              let cleanupPageSwitch,
              let displaysPageSwitch,
              let toolboxPageSwitch,
              let modelPageSwitch,
              let usagePageSwitch,
              let pageOrderPopup else { return }

        launchAtLoginSwitch.state = (loginStatus() == .enabled || loginStatus() == .requiresApproval) ? .on : .off
        keepAwakeSwitch.state = KeepAwakePreference.load(from: defaults) ? .on : .off
        hotCornerSwitch.state = defaults.bool(forKey: IntegratedHotCornerController.enabledDefaultsKey) ? .on : .off
        notificationsSwitch.state = defaults.bool(forKey: "dashboardNotificationsEnabled") ? .on : .off
        let savedInterval = MenuBarRefreshInterval.load(from: defaults)
        refreshIntervalPopup.selectItem(at: MenuBarRefreshInterval.allCases.firstIndex(of: savedInterval) ?? 1)

        let selectedMenuBarNumbers = MenuBarNumberOption.savedSelection(from: defaults)
        for (popup, option) in zip(menuBarLinePopups, MenuBarLineOption.savedSelection(from: defaults)) {
            popup.selectItem(at: MenuBarLineOption.allCases.firstIndex(of: option) ?? 0)
        }
        for (option, control) in menuBarNumberSwitches {
            control.state = selectedMenuBarNumbers.contains(option) ? .on : .off
        }
        statusPageSwitch.state = pageVisible("dashboardPageVisible1") ? .on : .off
        runningPageSwitch.state = pageVisible("dashboardPageVisible2") ? .on : .off
        powerPageSwitch.state = pageVisible("dashboardPageVisible3") ? .on : .off
        cleanupPageSwitch.state = pageVisible("dashboardPageVisible4") ? .on : .off
        modelPageSwitch.state = pageVisible("dashboardPageVisible5") ? .on : .off
        usagePageSwitch.state = pageVisible("dashboardPageVisible6") ? .on : .off
        toolboxPageSwitch.state = pageVisible("dashboardPageVisible7") ? .on : .off
        displaysPageSwitch.state = pageVisible("dashboardPageVisible8") ? .on : .off

        let order = defaults.string(forKey: "dashboardPageOrder") ?? "default"
        pageOrderPopup.selectItem(at: pageOrderOptions.firstIndex(where: { $0.value == order }) ?? 0)
        updatePageValidation()
    }

    @objc private func switchSettingsTab(_ sender: NSSegmentedControl) {
        if !(0...2).contains(sender.selectedSegment) { sender.selectedSegment = 0 }
        generalPane.isHidden = sender.selectedSegment != 0
        displayPane.isHidden = sender.selectedSegment != 1
        aboutPane.isHidden = sender.selectedSegment != 2
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func pinPane(_ pane: NSView, to host: NSView) {
        pane.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    private func scrollable(_ content: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        let clip = scroll.contentView
        let naturalHeight = document.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 8)
        // 低于窗口尺寸偏好，避免反向把滚动区（和整个窗口）压到内容高度。
        naturalHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -8),
            naturalHeight
        ])
        return scroll
    }

    private func makeGeneralPane() -> NSStackView {
        launchAtLoginSwitch = makeSwitch(on: false)
        keepAwakeSwitch = makeSwitch(on: false)
        hotCornerSwitch = makeSwitch(on: false)
        notificationsSwitch = makeSwitch(on: false)
        refreshIntervalPopup = makePopup(
            options: MenuBarRefreshInterval.allCases.map { ($0.title, $0.rawValue) },
            selected: MenuBarRefreshInterval.load(from: defaults).rawValue
        )
        return tabContent(sections: [
            settingsSection(title: "启动与屏幕", rows: [
                SettingsRowView(title: "开机启动", subtitle: "登录 Mac 时自动打开应用，保存后生效", control: launchAtLoginSwitch),
                SettingsRowView(title: "屏幕常亮", subtitle: "阻止显示器自动休眠（也可在工具页设倒计时）", control: keepAwakeSwitch),
                SettingsRowView(title: "左上角熄屏", subtitle: "指针停在屏幕左上角时触发硬件熄屏", control: hotCornerSwitch),
                SettingsRowView(title: "后台刷新间隔", subtitle: "控制菜单栏采样频率；熄屏时自动暂停轮询", control: refreshIntervalPopup)
            ]),
            settingsSection(title: "电池提醒", rows: [
                SettingsRowView(title: "提醒通知", subtitle: "低电量或电池/CPU 高温时后台提醒；需要系统通知权限", control: notificationsSwitch),
                paddedNote(notificationStatusLabel)
            ])
        ])
    }

    private func makeDisplayPane() -> NSStackView {
        let lineRows = MenuBarLineOption.savedSelection(from: defaults).enumerated().map { index, option -> NSView in
            let popup = makePopup(options: MenuBarLineOption.allCases.map { ($0.title, $0.rawValue) }, selected: option.rawValue)
            menuBarLinePopups.append(popup)
            return SettingsRowView(title: ["第一条（上）", "第二条（中）", "第三条（下）"][index], control: popup)
        }
        let lineNote = NSTextField(wrappingLabelWithString: "功率以 100 W 为满格，温度按 30–100°C 映射。负载越高越偏红；电量越低越偏红。仅在像素或数值变化时重绘。")
        let savedMenuBarNumbers = MenuBarNumberOption.savedSelection(from: defaults)
        let menuBarTooltips: [MenuBarNumberOption: String] = [
            .cpu: "在图标右侧显示 CPU 总使用率",
            .memory: "显示物理内存已用百分比",
            .cpuTemp: "显示处理器核心实时温度",
            .network: "显示紧凑实时总网速",
            .battery: "在图标右侧显示 Mac 剩余电量",
            .power: "显示当前实际功耗",
            .mouseBattery: "显示已连接鼠标或触控板电量"
        ]
        let menuBarRows = MenuBarNumberOption.allCases.map { option -> NSView in
            let control = makeSwitch(on: savedMenuBarNumbers.contains(option))
            menuBarNumberSwitches[option] = control
            return SettingsRowView(title: option.title, subtitle: menuBarTooltips[option], control: control)
        }

        statusPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible1"))
        runningPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible2"))
        powerPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible3"))
        cleanupPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible4"))
        displaysPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible8"))
        toolboxPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible7"))
        modelPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible5"))
        usagePageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible6"))
        pageOrderPopup = makePopup(
            options: pageOrderOptions.map { ($0.title, $0.value) },
            selected: defaults.string(forKey: "dashboardPageOrder") ?? "default"
        )

        return tabContent(sections: [
            settingsSection(title: "菜单栏进度线", rows: lineRows + [paddedNote(lineNote)]),
            settingsSection(title: "菜单栏数字", rows: menuBarRows),
            settingsSection(title: "显示页面", rows: [
                SettingsRowView(title: "状态", control: statusPageSwitch),
                SettingsRowView(title: "运行", control: runningPageSwitch),
                SettingsRowView(title: "电源", subtitle: "供电流向、附近 Apple 设备与无线外设电量", control: powerPageSwitch),
                SettingsRowView(title: "清理", subtitle: "四维物理内存透视释放与安全缓存清理", control: cleanupPageSwitch),
                SettingsRowView(title: "屏幕", subtitle: "屏幕亮度、显示布局与熄屏恢复", control: displaysPageSwitch),
                SettingsRowView(title: "工具", subtitle: "音频切换与音质守卫、常亮与桌面效率、网络速览", control: toolboxPageSwitch),
                SettingsRowView(title: "路由", control: modelPageSwitch),
                SettingsRowView(title: "用量", control: usagePageSwitch),
                SettingsRowView(title: "页面顺序", control: pageOrderPopup),
                paddedNote(pageValidationLabel)
            ])
        ])
    }

    private func makeAboutPane() -> NSView {
        let appName = AppBrand.displayName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "3.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"

        let iconView = NSImageView(image: AppBrand.icon(size: NSSize(width: 64, height: 64)))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64)
        ])

        let titleLabel = NSTextField(labelWithString: appName)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center

        let versionLabel = NSTextField(labelWithString: "版本 \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let privacy = NSTextField(wrappingLabelWithString: "所有系统数据均在本机读取和处理。")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        privacy.alignment = .center
        privacy.maximumNumberOfLines = 2

        let inner = NSStackView(views: [iconView, titleLabel, versionLabel, privacy])
        inner.orientation = .vertical
        inner.alignment = .centerX
        inner.spacing = 8
        inner.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        inner.setCustomSpacing(12, after: iconView)

        let card = SettingsFormCard(rows: [inner])
        card.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return content
    }

    private func tabContent(sections: [NSView]) -> NSStackView {
        let stack = FlippedSettingsStack(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        for section in sections { section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.distribution = .fill
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 6, right: 0)
        // 内容少于可视高度时保持自然高度，不把卡片拉伸出大片空白。
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        return stack
    }

    private func settingsSection(title: String, accessory: NSView? = nil, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heading)
        var headerConstraints = [
            header.heightAnchor.constraint(equalToConstant: 20),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            header.addSubview(accessory)
            headerConstraints.append(contentsOf: [
                accessory.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                accessory.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                heading.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8)
            ])
        }
        NSLayoutConstraint.activate(headerConstraints)

        let card = SettingsFormCard(rows: rows)
        let stack = NSStackView(views: [header, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 6
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func paddedNote(_ label: NSTextField) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    private func makeSwitch(on: Bool, action: Selector? = nil) -> NSSwitch {
        let control = NSSwitch()
        control.state = on ? .on : .off
        control.target = self
        control.action = action ?? #selector(updatePageValidation)
        return control
    }

    private func makePopup<Value: Equatable>(
        options: [(title: String, value: Value)],
        selected: Value
    ) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.bezelStyle = .rounded
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let index = options.firstIndex(where: { $0.value == selected }) {
            popup.selectItem(at: index)
        } else if let index = options.enumerated().min(by: { lhs, rhs in
            proximity(lhs.element.value, selected) < proximity(rhs.element.value, selected)
        })?.offset {
            popup.selectItem(at: index)
        }
        popup.translatesAutoresizingMaskIntoConstraints = false
        return popup
    }

    private func proximity<Value>(_ value: Value, _ selected: Value) -> Double {
        if let lhs = value as? Double, let rhs = selected as? Double {
            return abs(lhs - rhs)
        }
        if let lhs = value as? Int, let rhs = selected as? Int {
            return Double(abs(lhs - rhs))
        }
        return .greatestFiniteMagnitude
    }

    private func makeFooterButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        // 底部按钮保持固有高度，多余空间留给内容区，避免按钮被纵向拉伸。
        button.setContentHuggingPriority(.required, for: .vertical)
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        }
        return button
    }

    private func pageVisible(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    @objc private func updatePageValidation() {
        guard let statusPageSwitch, let runningPageSwitch, let powerPageSwitch, let cleanupPageSwitch, let displaysPageSwitch, let toolboxPageSwitch, let modelPageSwitch, let usagePageSwitch else { return }
        saveButton?.isEnabled = [statusPageSwitch, runningPageSwitch, powerPageSwitch, cleanupPageSwitch, displaysPageSwitch, toolboxPageSwitch, modelPageSwitch, usagePageSwitch].contains { $0.state == .on }
        let valid = saveButton?.isEnabled == true
        saveButton?.toolTip = valid ? "保存全部修改" : "至少保留一个页面"
        pageValidationLabel.stringValue = valid ? "至少保留一个页面。" : "至少保留一个页面，才能保存设置。"
        pageValidationLabel.textColor = valid ? .secondaryLabelColor : .systemRed
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc private func cancel() {
        view.window?.close()
    }

    func commitSettings() throws {
        guard [statusPageSwitch, runningPageSwitch, powerPageSwitch, cleanupPageSwitch, displaysPageSwitch, toolboxPageSwitch, modelPageSwitch, usagePageSwitch].contains(where: { $0?.state == .on }) else {
            throw NSError(domain: "DashboardSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "至少保留一个页面。"])
        }
        let requested = launchAtLoginSwitch.state == .on
        let status = loginStatus()
        if requested != (status == .enabled || status == .requiresApproval) {
            try applyLogin(requested)
            let actual = loginStatus()
            guard requested == (actual == .enabled || actual == .requiresApproval) else {
                throw NSError(domain: "DashboardSettings", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统没有应用登录项的更改，请检查系统设置。"])
            }
        }
        KeepAwakePreference.save(keepAwakeSwitch.state == .on, to: defaults)
        defaults.set(hotCornerSwitch.state == .on, forKey: IntegratedHotCornerController.enabledDefaultsKey)
        defaults.set(notificationsSwitch.state == .on, forKey: "dashboardNotificationsEnabled")
        if let rawInterval = refreshIntervalPopup.selectedItem?.representedObject as? Int,
           let interval = MenuBarRefreshInterval(rawValue: rawInterval) {
            MenuBarRefreshInterval.save(interval, to: defaults)
        }
        let selectedMenuBarNumbers = Set(
            menuBarNumberSwitches.compactMap { option, control in
                control.state == .on ? option : nil
            }
        )
        MenuBarNumberOption.saveSelection(selectedMenuBarNumbers, to: defaults)
        MenuBarLineOption.saveSelection(menuBarLinePopups.compactMap {
            ($0.selectedItem?.representedObject as? String).flatMap(MenuBarLineOption.init(rawValue:))
        }, to: defaults)
        let visiblePages: [Bool] = [
            statusPageSwitch.state == .on,
            runningPageSwitch.state == .on,
            powerPageSwitch.state == .on,
            cleanupPageSwitch.state == .on,
            modelPageSwitch.state == .on,
            usagePageSwitch.state == .on
        ]
        for (index, visible) in visiblePages.enumerated() {
            defaults.set(visible, forKey: "dashboardPageVisible\(index + 1)")
        }
        defaults.set(toolboxPageSwitch.state == .on, forKey: "dashboardPageVisible7")
        defaults.set(displaysPageSwitch.state == .on, forKey: "dashboardPageVisible8")
        if let order = pageOrderPopup.selectedItem?.representedObject as? String {
            defaults.set(order, forKey: "dashboardPageOrder")
        }
    }

    @objc private func save() {
        do { try commitSettings() }
        catch {
            showError("设置未保存", detail: error.localizedDescription)
            return
        }
        if loginStatus() == .requiresApproval {
            showError("开机启动等待批准", detail: "请在系统设置 → 通用 → 登录项中允许本应用。")
        }
        onSaved?()
        view.window?.close()
        if notificationsSwitch.state == .on {
            DashboardNotificationManager.shared.requestAuthorizationIfNeeded { [weak self] message in
                guard let message else { return }
                Task { @MainActor [weak self] in
                    self?.showError("偏好已保存，通知权限仍需处理", detail: message)
                }
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSettingsSaved: (() -> Void)?

    convenience init(contentController: AppSettingsViewController = AppSettingsViewController()) {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: SettingsLayout.windowWidth,
                height: SettingsLayout.windowHeight
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        contentController.onSaved = { [weak self] in
            self?.onSettingsSaved?()
        }
        window.contentViewController = contentController
        window.contentMinSize = NSSize(width: 480, height: 460)
        window.contentMaxSize = NSSize(width: 800, height: 900)
    }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true {
            (window?.contentViewController as? AppSettingsViewController)?.prepareForPresentation()
        }
        super.showWindow(sender)
        captureWindowIfRequested()
    }

    /// 调试用：设置 SETTINGS_CAPTURE_PNG 环境变量后，把设置窗口渲染成 PNG 再退出，
    /// 供脚本在无录屏权限的终端里做排版检查（沿用 --show 调试抓帧的既有做法）。
    private func captureWindowIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SETTINGS_CAPTURE_PNG"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            defer { exit(0) }
            guard let window = self?.window else { return }
            let windowID = CGWindowID(window.windowNumber)
            if
                let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], windowID, [.bestResolution]),
                let composited = Self.compositeOverOpaqueBackground(image)
            {
                try? composited.write(to: URL(fileURLWithPath: path))
            }
            let pdfData = window.contentView?.dataWithPDF(inside: window.contentView?.bounds ?? .zero)
            if let pdfData, !pdfData.isEmpty {
                try? pdfData.write(to: URL(fileURLWithPath: path + ".pdf"))
            }
        }
    }

    private static func compositeOverOpaqueBackground(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: image.width,
            pixelsHigh: image.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        rep?.size = NSSize(width: image.width / 2, height: image.height / 2)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            .draw(in: NSRect(x: 0, y: 0, width: image.width / 2, height: image.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func windowWillClose(_ notification: Notification) {}
}

@MainActor
private enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    /// 通用页内容全部展开后的理想高度；超过屏幕可用高度时自动收缩（此时可滚动）。
    static let idealWindowHeight: CGFloat = 680
    static var windowHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? idealWindowHeight
        return min(idealWindowHeight, available - 40)
    }
}

@MainActor
private final class FlippedSettingsStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsFormCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        applyFill()

        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                arranged.append(Self.divider())
            }
            arranged.append(row)
        }
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        // .width 只让各行彼此等宽，并不会贴住卡片两侧（会导致行内容整体偏右）；
        // 这里改为显式约束每一行的左右边距。
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .vertical)
        addSubview(stack)
        for view in arranged {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right)
            ])
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    static func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func applyFill() {
        var fill = NSColor.labelColor.withAlphaComponent(0.028).cgColor
        var border = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.labelColor.withAlphaComponent(0.028).cgColor
            border = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
        layer?.backgroundColor = fill
        layer?.borderColor = border
    }
}

@MainActor
private final class SettingsRowView: NSView {
    private weak var interactiveControl: NSView?

    init(title: String, subtitle: String? = nil, control: NSView, toolTip: String? = nil) {
        super.init(frame: .zero)
        interactiveControl = control
        translatesAutoresizingMaskIntoConstraints = false
        self.toolTip = toolTip

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)
        control.setAccessibilityHelp(subtitle ?? toolTip)
        control.identifier = NSUserInterfaceItemIdentifier("settings.\(title)")
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(control)

        let titleCenter: NSLayoutConstraint
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subtitleLabel)
            titleCenter = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8)
            NSLayoutConstraint.activate([
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                subtitleLabel.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16),
                subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            ])
        } else {
            titleCenter = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            heightAnchor.constraint(equalToConstant: 40).isActive = true
        }

        if control is NSPopUpButton {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleCenter,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -10),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 位于父视图坐标系，先转成本地坐标再比较（NSView 与 UIKit 不同）
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local) else { return nil }
        // 优先把事件路由给交互控件（NSSwitch / NSPopUpButton）
        if let interactiveControl {
            let controlPoint = convert(local, to: interactiveControl)
            if interactiveControl.bounds.contains(controlPoint) {
                return interactiveControl
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if let control = interactiveControl as? NSControl, control.isEnabled {
            control.performClick(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
