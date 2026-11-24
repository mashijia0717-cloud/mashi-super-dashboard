import AppKit

@MainActor
final class RunningAppsToolbarView: NSView, NSSearchFieldDelegate {
    var onChange: ((RunningAppsSortMode) -> Void)?
    var onSubmodeChange: ((RunningPageSubmode) -> Void)?
    var onSearchChange: ((String) -> Void)?
    var onRefreshPorts: (() -> Void)?

    private let submodeSegment = NSSegmentedControl(labels: RunningPageSubmode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let popup = NSPopUpButton()
    private let refreshPortsButton = NSButton()
    private let searchField = NSSearchField()

    init(mode: RunningAppsSortMode, submode: RunningPageSubmode = .apps, query: String = "") {
        super.init(frame: .zero)
        submodeSegment.selectedSegment = RunningPageSubmode.allCases.firstIndex(of: submode) ?? 0
        submodeSegment.controlSize = .small
        submodeSegment.segmentStyle = .rounded
        submodeSegment.target = self
        submodeSegment.action = #selector(submodeChanged)
        submodeSegment.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        popup.addItems(withTitles: RunningAppsSortMode.allCases.map(\.title))
        popup.selectItem(at: RunningAppsSortMode.allCases.firstIndex(of: mode) ?? 0)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(changed)
        popup.translatesAutoresizingMaskIntoConstraints = false

        refreshPortsButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新端口")
        refreshPortsButton.imagePosition = .imageOnly
        refreshPortsButton.controlSize = .small
        refreshPortsButton.bezelStyle = .inline
        refreshPortsButton.isBordered = false
        refreshPortsButton.contentTintColor = .secondaryLabelColor
        refreshPortsButton.toolTip = "重新扫描本机监听端口"
        refreshPortsButton.target = self
        refreshPortsButton.action = #selector(refreshPortsTapped)
        refreshPortsButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11.5)
        searchField.stringValue = query
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(submodeSegment)
        addSubview(summaryLabel)
        addSubview(popup)
        addSubview(refreshPortsButton)
        addSubview(searchField)
        NSLayoutConstraint.activate([
            submodeSegment.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            submodeSegment.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            submodeSegment.widthAnchor.constraint(equalToConstant: 96),
            summaryLabel.leadingAnchor.constraint(equalTo: submodeSegment.trailingAnchor, constant: 8),
            summaryLabel.centerYAnchor.constraint(equalTo: submodeSegment.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -6),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            popup.centerYAnchor.constraint(equalTo: submodeSegment.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 90),
            refreshPortsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            refreshPortsButton.centerYAnchor.constraint(equalTo: submodeSegment.centerYAnchor),
            refreshPortsButton.widthAnchor.constraint(equalToConstant: 24),
            refreshPortsButton.heightAnchor.constraint(equalToConstant: 24),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            searchField.topAnchor.constraint(equalTo: submodeSegment.bottomAnchor, constant: 6),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        applySubmode(submode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSummary(_ text: String, submode: RunningPageSubmode, mode: RunningAppsSortMode) {
        summaryLabel.stringValue = text
        let targetSegment = RunningPageSubmode.allCases.firstIndex(of: submode) ?? 0
        if submodeSegment.selectedSegment != targetSegment {
            submodeSegment.selectedSegment = targetSegment
        }
        let targetSort = RunningAppsSortMode.allCases.firstIndex(of: mode) ?? 0
        if popup.indexOfSelectedItem != targetSort {
            popup.selectItem(at: targetSort)
        }
        applySubmode(submode)
    }

    private func applySubmode(_ submode: RunningPageSubmode) {
        popup.isHidden = submode != .apps
        refreshPortsButton.isHidden = submode != .ports
        searchField.placeholderString = submode == .apps ? "搜索应用名称或 Bundle ID…" : "搜索端口号（如 3000）、进程名或 PID…"
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChange?(searchField.stringValue)
    }

    @objc private func submodeChanged() {
        let idx = min(max(0, submodeSegment.selectedSegment), RunningPageSubmode.allCases.count - 1)
        let next = RunningPageSubmode.allCases[idx]
        applySubmode(next)
        onSubmodeChange?(next)
    }

    @objc private func refreshPortsTapped() {
        onRefreshPorts?()
    }

    @objc private func changed() {
        let index = min(
            max(0, popup.indexOfSelectedItem),
            RunningAppsSortMode.allCases.count - 1
        )
        onChange?(RunningAppsSortMode.allCases[index])
    }
}

class RunningAppRowView: LiquidGlassCardView {
    private(set) var app: RunningApp
    var onKill: (() -> Void)?
    var onGracefulQuit: (() -> Void)?

    private static var iconCache: [String: NSImage] = [:]
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let finderButton = NSButton()
    private let killButton = NSButton()
    private var hoverTrackingArea: NSTrackingArea?

    init(app: RunningApp, frame: NSRect = .zero) {
        self.app = app
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        detailLabel.stringValue = [
            formatMemory(app.residentMemoryBytes),
            app.cpuUsage.map { String(format: "CPU %.1f%%", $0 * 100) } ?? "CPU 采样中",
            app.energyLevel,
            formatDuration(app.runningDuration)
        ].joined(separator: " · ")
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        finderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "在访达中显示")
        finderButton.imagePosition = .imageOnly
        finderButton.contentTintColor = .secondaryLabelColor
        finderButton.bezelStyle = .inline
        finderButton.isBordered = false
        finderButton.target = self
        finderButton.action = #selector(revealInFinder)
        finderButton.alphaValue = 0.0
        finderButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(finderButton)

        killButton.imagePosition = .imageOnly
        killButton.contentTintColor = .systemRed
        killButton.bezelStyle = .inline
        killButton.isBordered = false
        killButton.target = self
        killButton.action = #selector(killAction)
        killButton.alphaValue = 0.18
        killButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(killButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: finderButton.leadingAnchor, constant: -6),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: finderButton.leadingAnchor, constant: -6),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            finderButton.trailingAnchor.constraint(equalTo: killButton.leadingAnchor, constant: -2),
            finderButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            finderButton.widthAnchor.constraint(equalToConstant: 26),
            finderButton.heightAnchor.constraint(equalToConstant: 28),

            killButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            killButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            killButton.widthAnchor.constraint(equalToConstant: 32),
            killButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        update(app: app)
    }

    func update(app: RunningApp) {
        self.app = app
        iconView.image = Self.cachedIcon(for: app)
        nameLabel.stringValue = app.localizedName
        detailLabel.stringValue = [
            formatMemory(app.residentMemoryBytes),
            app.cpuUsage.map { String(format: "CPU %.1f%%", $0 * 100) } ?? "CPU 采样中",
            app.energyLevel,
            formatDuration(app.runningDuration)
        ].joined(separator: " · ")
        finderButton.toolTip = "在访达中显示 \(app.localizedName)"
        killButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "退出或强制退出 \(app.localizedName)")
        killButton.toolTip = "点击强制退出（右键可普通退出或定位访达）"
        killButton.setAccessibilityLabel("退出 \(app.localizedName)")
        toolTip = "\(app.localizedName) (PID \(app.identity.processIdentifier))\(app.bundleIdentifier.map { " · \($0)" } ?? "")"
    }

    private static func cachedIcon(for app: RunningApp) -> NSImage? {
        let cacheKey = app.bundleIdentifier ?? app.executableURL?.path ?? app.localizedName
        if let cached = iconCache[cacheKey] { return cached }
        let resolved: NSImage?
        if let bundleId = app.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        } else if let execUrl = app.executableURL {
            resolved = NSWorkspace.shared.icon(forFile: execUrl.path)
        } else {
            resolved = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        }
        if let resolved {
            if iconCache.count > 200 { iconCache.removeAll(keepingCapacity: true) }
            iconCache[cacheKey] = resolved
        }
        return resolved
    }

    @objc private func killAction() {
        onKill?()
    }

    @objc private func gracefulQuitAction() {
        onGracefulQuit?()
    }

    @objc private func revealInFinder() {
        if let bundleID = app.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } else if let execURL = app.executableURL {
            NSWorkspace.shared.activateFileViewerSelecting([execURL])
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "普通退出“\(app.localizedName)”", action: #selector(gracefulQuitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        let forceItem = NSMenuItem(title: "强制退出“\(app.localizedName)”…", action: #selector(killAction), keyEquivalent: "")
        forceItem.target = self
        menu.addItem(forceItem)
        menu.addItem(.separator())
        let finderItem = NSMenuItem(title: "在访达中显示", action: #selector(revealInFinder), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(hoverTrackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        finderButton.animator().alphaValue = 0.85
        killButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        finderButton.animator().alphaValue = 0.0
        killButton.animator().alphaValue = 0.18
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "运行 \(minutes) 分钟" }
        if minutes < 24 * 60 { return "运行 \(minutes / 60) 小时" }
        return "运行 \(minutes / (24 * 60)) 天"
    }
}

@MainActor
final class ListeningPortRowView: LiquidGlassCardView {
    private(set) var item: ListeningPortItem
    var onTerminatePID: ((ListeningPortItem) -> Void)?
    var onCopied: ((String) -> Void)?

    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let openButton = NSButton()
    private let stopButton = NSButton()
    private var hoverArea: NSTrackingArea?

    init(item: ListeningPortItem) {
        self.item = item
        super.init(frame: .zero)
        setup()
        update(item: item)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        badgeLabel.textColor = .systemBlue
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 6
        badgeLabel.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        for (btn, sym, tip, act) in [
            (copyButton, "doc.on.doc", "复制地址", #selector(copyAddress)),
            (openButton, "safari", "在浏览器打开", #selector(openInBrowser)),
            (stopButton, "xmark.circle.fill", "结束监听进程", #selector(stopProcess))
        ] {
            btn.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            btn.imagePosition = .imageOnly
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.contentTintColor = btn === stopButton ? .systemRed : .secondaryLabelColor
            btn.toolTip = tip
            btn.target = self
            btn.action = act
            btn.alphaValue = btn === stopButton ? 0.22 : 0.0
            btn.translatesAutoresizingMaskIntoConstraints = false
            addSubview(btn)
        }

        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            badgeLabel.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -6),

            copyButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),

            openButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -2),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 24),
            openButton.heightAnchor.constraint(equalToConstant: 24),

            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 28),
            stopButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func update(item: ListeningPortItem) {
        self.item = item
        badgeLabel.stringValue = ":\(item.port)"
        titleLabel.stringValue = item.processName
        detailLabel.stringValue = "\(item.address) · PID \(item.pid)"
        toolTip = "\(item.processName) 监听 \(item.address) (PID \(item.pid))"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        copyButton.animator().alphaValue = 0.85
        openButton.animator().alphaValue = 0.85
        stopButton.animator().alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        copyButton.animator().alphaValue = 0.0
        openButton.animator().alphaValue = 0.0
        stopButton.animator().alphaValue = 0.22
    }

    @objc private func copyAddress() {
        let text = "http://127.0.0.1:\(item.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied?("已复制 \(text)")
    }

    @objc private func openInBrowser() {
        guard let url = item.browserURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func stopProcess() {
        onTerminatePID?(item)
    }
}
