import AppKit

@MainActor
final class RunningAppsToolbarView: NSView {
    var onChange: ((RunningAppsSortMode) -> Void)?
    private let popup = NSPopUpButton()

    init(mode: RunningAppsSortMode) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "运行中的应用")
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: RunningAppsSortMode.allCases.map(\.title))
        popup.selectItem(at: RunningAppsSortMode.allCases.firstIndex(of: mode) ?? 0)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(changed)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 94)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() {
        let index = min(
            max(0, popup.indexOfSelectedItem),
            RunningAppsSortMode.allCases.count - 1
        )
        onChange?(RunningAppsSortMode.allCases[index])
    }
}

class RunningAppRowView: LiquidGlassCardView {
    let app: RunningApp
    var onKill: (() -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
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
        if let bundleId = app.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let execUrl = app.executableURL {
            iconView.image = NSWorkspace.shared.icon(forFile: execUrl.path)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.stringValue = app.localizedName
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

        killButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "强制退出 \(app.localizedName)")
        killButton.imagePosition = .imageOnly
        killButton.contentTintColor = .systemRed
        killButton.bezelStyle = .inline
        killButton.toolTip = "强制退出 \(app.localizedName)"
        killButton.setAccessibilityLabel("强制退出 \(app.localizedName)")
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
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: killButton.leadingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: killButton.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            killButton.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            killButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            killButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            killButton.widthAnchor.constraint(equalToConstant: 44),
            killButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func killAction() {
        onKill?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(hoverTrackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        killButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
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
