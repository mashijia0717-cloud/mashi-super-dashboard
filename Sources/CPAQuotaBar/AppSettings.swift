import AppKit
import ServiceManagement

@MainActor
final class AppSettingsViewController: NSViewController {
    var onSaved: (() -> Void)?

    private var launchAtLoginSwitch: NSSwitch!
    private var keepAwakeSwitch: NSSwitch!
    private var notificationsSwitch: NSSwitch!
    private var menuBarNumberSwitches: [MenuBarNumberOption: NSSwitch] = [:]
    private var statusPageSwitch: NSSwitch!
    private var runningPageSwitch: NSSwitch!
    private var powerPageSwitch: NSSwitch!
    private var cleanupPageSwitch: NSSwitch!
    private var pageOrderPopup: NSPopUpButton!
    private var generalPane: NSView!
    private var aboutPane: NSView!
    private var generalScroll: NSScrollView!

    private let pageOrderOptions: [(title: String, value: String)] = [
        ("默认顺序", "default"),
        ("电源优先", "powerFirst"),
        ("状态优先", "statusFirst"),
        ("清理优先", "cleanFirst")
    ]

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundle: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadSettingsFromDefaults()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight))
        container.translatesAutoresizingMaskIntoConstraints = false

        let tabControl = NSSegmentedControl(
            labels: ["通用", "关于"],
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
        aboutPane = makeAboutPane()
        pinPane(generalPane, to: panes)
        pinPane(aboutPane, to: panes)
        aboutPane.isHidden = true

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerSeparator)

        let cancelButton = makeFooterButton(title: "取消", action: #selector(cancel))
        let saveButton = makeFooterButton(title: "保存", action: #selector(save))
        saveButton.keyEquivalent = "\r"
        container.addSubview(cancelButton)
        container.addSubview(saveButton)

        NSLayoutConstraint.activate([
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

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            glass.addSubview(container)
            view = glass
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(container)
            view = effect
        }
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
              let notificationsSwitch,
              let statusPageSwitch,
              let runningPageSwitch,
              let powerPageSwitch,
              let cleanupPageSwitch,
              let pageOrderPopup else { return }

        launchAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        keepAwakeSwitch.state = KeepAwakePreference.load() ? .on : .off
        notificationsSwitch.state = UserDefaults.standard.bool(forKey: "dashboardNotificationsEnabled") ? .on : .off

        let selectedMenuBarNumbers = MenuBarNumberOption.savedSelection()
        for (option, control) in menuBarNumberSwitches {
            control.state = selectedMenuBarNumbers.contains(option) ? .on : .off
        }
        statusPageSwitch.state = pageVisible("dashboardPageVisible1") ? .on : .off
        runningPageSwitch.state = pageVisible("dashboardPageVisible2") ? .on : .off
        powerPageSwitch.state = pageVisible("dashboardPageVisible3") ? .on : .off
        cleanupPageSwitch.state = pageVisible("dashboardPageVisible4") ? .on : .off

        let order = UserDefaults.standard.string(forKey: "dashboardPageOrder") ?? "default"
        if let index = pageOrderOptions.firstIndex(where: { $0.value == order }) {
            pageOrderPopup.selectItem(at: index)
        }
    }

    @objc private func switchSettingsTab(_ sender: NSSegmentedControl) {
        generalPane.isHidden = sender.selectedSegment != 0
        aboutPane.isHidden = sender.selectedSegment != 1
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
        scroll.documentView = content
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor)
        ])
        return scroll
    }

    private func makeGeneralPane() -> NSStackView {
        launchAtLoginSwitch = makeSwitch(
            on: SMAppService.mainApp.status == .enabled,
            action: #selector(toggleLaunchAtLogin(_:))
        )
        keepAwakeSwitch = makeSwitch(on: KeepAwakePreference.load())
        notificationsSwitch = makeSwitch(
            on: UserDefaults.standard.bool(forKey: "dashboardNotificationsEnabled")
        )

        let savedMenuBarNumbers = MenuBarNumberOption.savedSelection()
        let menuBarTooltips: [MenuBarNumberOption: String] = [
            .battery: "在图标右侧显示 Mac 剩余电量",
            .power: "显示当前实际功耗",
            .mouseBattery: "显示已连接鼠标或触控板电量"
        ]
        let menuBarRows = MenuBarNumberOption.allCases.map { option -> NSView in
            let control = makeSwitch(on: savedMenuBarNumbers.contains(option))
            menuBarNumberSwitches[option] = control
            return SettingsRowView(title: option.title, control: control, toolTip: menuBarTooltips[option])
        }

        statusPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible1"))
        runningPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible2"))
        powerPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible3"))
        cleanupPageSwitch = makeSwitch(on: pageVisible("dashboardPageVisible4"))
        pageOrderPopup = makePopup(
            options: pageOrderOptions.map { ($0.title, $0.value) },
            selected: UserDefaults.standard.string(forKey: "dashboardPageOrder") ?? "default"
        )

        return tabContent(sections: [
            settingsSection(title: "启动", rows: [
                SettingsRowView(title: "开机启动", control: launchAtLoginSwitch, toolTip: "登录 Mac 时自动打开菜单栏应用"),
                SettingsRowView(title: "屏幕常亮", control: keepAwakeSwitch, toolTip: "阻止显示器自动休眠")
            ]),
            settingsSection(title: "菜单栏数字", rows: menuBarRows),
            settingsSection(title: "显示页面", rows: [
                SettingsRowView(title: "状态", control: statusPageSwitch),
                SettingsRowView(title: "运行", control: runningPageSwitch),
                SettingsRowView(title: "电源", control: powerPageSwitch),
                SettingsRowView(title: "清理", control: cleanupPageSwitch),
                SettingsRowView(title: "页面顺序", control: pageOrderPopup)
            ]),
            settingsSection(title: "提醒", rows: [
                SettingsRowView(title: "提醒通知", control: notificationsSwitch, toolTip: "电池电量偏低或温度偏高时通知")
            ])
        ])
    }

    private func makeAboutPane() -> NSView {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? AppBrand.displayName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
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
        privacy.textColor = .tertiaryLabelColor
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
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
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
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
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
        card.widthAnchor.constraint(equalToConstant: SettingsLayout.windowWidth - 40).isActive = true
        let stack = NSStackView(views: [header, card])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 5
        // 让每个分组都占满设置内容区；否则没有长文本的分组会按控件
        // 的固有宽度收缩到右侧窄列，造成布局和点按区域都不一致。
        stack.widthAnchor.constraint(equalToConstant: SettingsLayout.windowWidth - 40).isActive = true
        return stack
    }

    private func paddedNote(_ label: NSTextField) -> NSView {
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return box
    }

    private func makeSwitch(on: Bool, action: Selector? = nil) -> NSSwitch {
        let control = NSSwitch()
        control.state = on ? .on : .off
        if let action {
            control.target = self
            control.action = action
        }
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
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        }
        return button
    }

    private func pageVisible(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = sender.state == .on ? .off : .on
            showError("设置开机启动失败", detail: error.localizedDescription)
        }
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

    @objc private func save() {
        let defaults = UserDefaults.standard
        KeepAwakePreference.save(keepAwakeSwitch.state == .on)
        defaults.set(notificationsSwitch.state == .on, forKey: "dashboardNotificationsEnabled")
        let selectedMenuBarNumbers = Set(
            menuBarNumberSwitches.compactMap { option, control in
                control.state == .on ? option : nil
            }
        )
        MenuBarNumberOption.saveSelection(selectedMenuBarNumbers)
        var visiblePages: [Bool] = [
            statusPageSwitch.state == .on,
            runningPageSwitch.state == .on,
            powerPageSwitch.state == .on,
            cleanupPageSwitch.state == .on
        ]
        // 至少保留一个页面，避免保存后导航栏为空且设置页与实际页面不一致。
        if !visiblePages.contains(true) {
            visiblePages[0] = true
            statusPageSwitch.state = .on
        }
        for (index, visible) in visiblePages.enumerated() {
            defaults.set(visible, forKey: "dashboardPageVisible\(index + 1)")
        }
        if let order = pageOrderPopup.selectedItem?.representedObject as? String {
            defaults.set(order, forKey: "dashboardPageOrder")
        }
        DashboardNotificationManager.shared.requestAuthorizationIfNeeded()
        onSaved?()
        view.window?.close()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSettingsSaved: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: SettingsLayout.windowWidth,
                height: SettingsLayout.windowHeight
            ),
            styleMask: [.titled, .closable],
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
        let contentController = AppSettingsViewController()
        contentController.onSaved = { [weak self] in
            self?.onSettingsSaved?()
        }
        window.contentViewController = contentController
    }

    override func showWindow(_ sender: Any?) {
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
    static let windowWidth: CGFloat = 520
    /// 通用页内容全部展开后的理想高度；超过屏幕可用高度时自动收缩（此时可滚动）。
    static let idealWindowHeight: CGFloat = 742
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
        stack.alignment = .width
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
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
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(control)

        let titleCenter: NSLayoutConstraint
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .tertiaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subtitleLabel)
            titleCenter = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6)
            NSLayoutConstraint.activate([
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -10),
                subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
            ])
        } else {
            titleCenter = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleCenter,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -10),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let interactiveControl, interactiveControl.frame.contains(point) {
            return interactiveControl
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if let control = interactiveControl as? NSControl {
            control.performClick(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
