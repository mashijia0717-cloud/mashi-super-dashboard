import AppKit
import QuartzCore

@MainActor
private enum PowerPalette {
    static var primary: NSColor { .labelColor }
    static var secondary: NSColor { .secondaryLabelColor }
    static var tertiary: NSColor { .tertiaryLabelColor }
    static var surface: NSColor { .labelColor.withAlphaComponent(0.028) }
    static var border: NSColor { .labelColor.withAlphaComponent(0.05) }
    static var track: NSColor { .labelColor.withAlphaComponent(0.04) }

    static func cg(_ color: NSColor, in view: NSView) -> CGColor {
        var result: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}

@MainActor
final class PowerFlowDashboardView: NSView {
    var onHeightChanged: (() -> Void)?
    private let limitPill = PowerStatusPill()
    private let modePill = PowerStatusPill()
    private let adapterPill = PowerStatusPill()
    private let batteryBar = BatteryChargeBarView()
    private let nearbyBatteryBars = NearbyDeviceBatteryGroupView()
    private let flowView = PowerFlowCanvasView()
    private let detailsCard = PowerDetailsCardView()
    private var nearbyHeightConstraint: NSLayoutConstraint?
    private var dashboardHeightConstraint: NSLayoutConstraint?

    init(snapshot: PowerFlowSnapshot = .placeholder) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 372).isActive = true
        let dashboardHeight = heightAnchor.constraint(
            equalToConstant: nearbyBatteryBars.isExpanded ? 528 : 436
        )
        dashboardHeight.isActive = true
        dashboardHeightConstraint = dashboardHeight

        let stateRow = NSStackView(views: [limitPill, modePill, adapterPill])
        stateRow.orientation = .horizontal
        stateRow.alignment = .height
        stateRow.distribution = .fillEqually
        stateRow.spacing = 8
        stateRow.translatesAutoresizingMaskIntoConstraints = false
        stateRow.heightAnchor.constraint(equalToConstant: 32).isActive = true

        batteryBar.translatesAutoresizingMaskIntoConstraints = false
        batteryBar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        nearbyBatteryBars.translatesAutoresizingMaskIntoConstraints = false
        let nearbyHeight = nearbyBatteryBars.heightAnchor.constraint(
            equalToConstant: nearbyBatteryBars.isExpanded ? 126 : 34
        )
        nearbyHeight.isActive = true
        nearbyHeightConstraint = nearbyHeight
        nearbyBatteryBars.onExpansionChanged = { [weak self] expanded in
            guard let self else { return }
            self.nearbyHeightConstraint?.constant = expanded ? 126 : 34
            self.dashboardHeightConstraint?.constant = expanded ? 528 : 436
            self.invalidateIntrinsicContentSize()
            self.superview?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.onHeightChanged?()
            }
        }
        flowView.translatesAutoresizingMaskIntoConstraints = false
        flowView.heightAnchor.constraint(equalToConstant: 132).isActive = true
        detailsCard.translatesAutoresizingMaskIntoConstraints = false
        detailsCard.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let stack = NSStackView(views: [stateRow, batteryBar, nearbyBatteryBars, flowView, detailsCard])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        limitPill.onClick = { [weak self] in
            self?.openBatterySettings()
        }
        update(snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: PowerFlowSnapshot) {
        let routing = PowerFlowRouting(snapshot: snapshot)
        let limit = snapshot.chargeLimitPercent.map { "限制 \($0)%" } ?? "系统管理"
        limitPill.update(title: limit, symbol: "battery.75percent")
        limitPill.toolTip = "点击打开 macOS 电池设置调整充电限制"

        let modeSymbol: String
        switch routing.mode {
        case .adapterCharging:
            modeSymbol = "bolt.fill"
        case .adapterDirect:
            modeSymbol = "pause.fill"
        case .batteryOnly:
            modeSymbol = "battery.50percent"
        case .adapterWithBatteryAssist:
            modeSymbol = "arrow.triangle.merge"
        }
        modePill.update(title: routing.title, symbol: modeSymbol)

        // 顶部显示当前实际输入功率；适配器额定能力在下方详情中单独显示，避免把
        // 固定的 65 W 额定值误认为实时功率。
        let actualInput: Double?
        if snapshot.externalConnected {
            actualInput = routing.adapterOutputWatts > 0
                ? routing.adapterOutputWatts
                : snapshot.inputWatts
        } else {
            actualInput = nil
        }
        let adapter = actualInput.map { String(format: "输入 %.1fW", $0) } ?? "输入 --"
        adapterPill.update(title: adapter, symbol: "powerplug.fill")

        batteryBar.update(snapshot)
        nearbyBatteryBars.update(snapshot.nearbyDevices)
        flowView.update(snapshot)
        detailsCard.update(snapshot)

        setAccessibilityRole(.group)
        setAccessibilityLabel("电源流向")
        setAccessibilityValue("\(percent(snapshot.batteryLevel))，\(routing.title)")
    }

    private func openBatterySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery"
        ].compactMap(URL.init(string:))
        guard !urls.contains(where: { NSWorkspace.shared.open($0) }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开电池设置"
        alert.informativeText = "请在系统设置中打开“电池”，再进入“充电”旁的信息按钮调整限制。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "电量未知"
    }
}

@MainActor
private final class NearbyDeviceBatteryGroupView: NSView {
    private var rows: [NearbyAppleDeviceKind: NearbyDeviceBatteryBarView] = [:]
    private let rowsStack = NSStackView()
    private let disclosure = NSButton()
    var onExpansionChanged: ((Bool) -> Void)?
    private(set) var isExpanded = UserDefaults.standard.object(
        forKey: "nearbyDevicesExpanded"
    ) as? Bool ?? true

    override init(frame: NSRect) {
        super.init(frame: frame)
        let rowViews = NearbyAppleDeviceKind.allCases.map { kind in
            let row = NearbyDeviceBatteryBarView(kind: kind)
            rows[kind] = row
            return row
        }
        rowsStack.setViews(rowViews, in: .top)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.distribution = .fillEqually
        rowsStack.spacing = 5

        let title = NSTextField(labelWithString: "附近设备")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = PowerPalette.secondary
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        disclosure.isBordered = false
        disclosure.bezelStyle = .inline
        disclosure.target = self
        disclosure.action = #selector(toggleExpanded)
        let header = NSStackView(views: [title, headerSpacer, disclosure])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let stack = NSStackView(views: [header, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyExpansion()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ devices: [NearbyAppleDeviceBattery]) {
        let values = Dictionary(uniqueKeysWithValues: devices.map { ($0.kind, $0) })
        for kind in NearbyAppleDeviceKind.allCases {
            rows[kind]?.update(values[kind] ?? .placeholder(for: kind))
        }
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        UserDefaults.standard.set(isExpanded, forKey: "nearbyDevicesExpanded")
        applyExpansion()
        onExpansionChanged?(isExpanded)
    }

    private func applyExpansion() {
        rowsStack.isHidden = !isExpanded
        disclosure.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )
        disclosure.contentTintColor = PowerPalette.secondary
        disclosure.setAccessibilityLabel(isExpanded ? "折叠附近设备" : "展开附近设备")
    }
}

@MainActor
private final class NearbyDeviceBatteryBarView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "正在搜索…")
    private var level: Double?

    init(kind: NearbyAppleDeviceKind) {
        super.init(frame: .zero)
        wantsLayer = true

        track.backgroundColor = PowerPalette.cg(PowerPalette.track, in: self)
        track.borderColor = PowerPalette.cg(PowerPalette.border, in: self)
        track.borderWidth = 0.75
        layer?.addSublayer(track)

        fill.colors = [
            NSColor.systemBlue.withAlphaComponent(0.44).cgColor,
            NSColor.systemTeal.withAlphaComponent(0.25).cgColor
        ]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(fill)

        icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = PowerPalette.secondary
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = kind.displayName
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        nameLabel.textColor = PowerPalette.primary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        valueLabel.textColor = PowerPalette.secondary
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 178),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8)
        ])
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(kind.displayName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        track.frame = rect
        track.cornerRadius = rect.height / 2
        let width = level.map { rect.width * CGFloat($0) } ?? 0
        fill.frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        fill.cornerRadius = rect.height / 2
    }

    func update(_ device: NearbyAppleDeviceBattery) {
        nameLabel.stringValue = device.name
        level = device.level.map { min(max($0, 0), 1) }
        switch device.availability {
        case .available:
            let percent = Int(((level ?? 0) * 100).rounded())
            valueLabel.stringValue = device.isCharging ? "\(percent)% 充电中" : "\(percent)%"
            valueLabel.textColor = PowerPalette.primary
            toolTip = device.lastUpdated.map {
                "更新于 \($0.formatted(date: .omitted, time: .standard))"
            }
        case .scanning:
            valueLabel.stringValue = "正在搜索…"
            valueLabel.textColor = PowerPalette.secondary
            toolTip = "正在搜索同一局域网中的已配对设备"
        case .pairingRequired:
            valueLabel.stringValue = "需开启 Wi‑Fi 同步"
            valueLabel.textColor = NSColor.systemOrange.withAlphaComponent(0.90)
            toolTip = "请先用数据线连接并信任此 Mac，再在 Finder 中开启“连接到 Wi‑Fi 时显示此设备”"
        case .notFound:
            valueLabel.stringValue = device.lastUpdated.map {
                "上次 \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "未发现"
            valueLabel.textColor = PowerPalette.tertiary
            toolTip = "设备未在附近，或尚未与这台 Mac 配对"
        }
        fill.colors = (level ?? 1) <= 0.2
            ? [NSColor.systemRed.withAlphaComponent(0.55).cgColor, NSColor.systemOrange.withAlphaComponent(0.30).cgColor]
            : [NSColor.systemBlue.withAlphaComponent(0.44).cgColor, NSColor.systemTeal.withAlphaComponent(0.25).cgColor]
        setAccessibilityLabel(device.name)
        setAccessibilityValue(valueLabel.stringValue)
        needsLayout = true
    }
}

@MainActor
private final class PowerStatusPill: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)? {
        didSet {
            setAccessibilityRole(onClick == nil ? .group : .button)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        applyMenuChrome()

        icon.contentTintColor = PowerPalette.secondary
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = PowerPalette.primary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMenuChrome()
    }

    private func applyMenuChrome() {
        layer?.backgroundColor = PowerPalette.cg(PowerPalette.surface, in: self)
        layer?.borderColor = PowerPalette.cg(PowerPalette.border, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else {
            super.mouseDown(with: event)
            return
        }
        onClick()
    }

    // 图标和文字是子视图；将命中测试统一收敛到胶囊本身，避免点到文字时
    // 事件被 NSTextField/NSImageView 吃掉，导致“点击电池设置”偶尔无效。
    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick == nil ? super.hitTest(point) : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onClick != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func update(title: String, symbol: String) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(title)
    }
}

@MainActor
private final class BatteryChargeBarView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private let shimmer = CAGradientLayer()
    private let label = NSTextField(labelWithString: "--%")
    private let stateLabel = NSTextField(labelWithString: "正在读取电池")
    private let powerIcon = NSImageView()
    private var level: Double = 0
    private var isCharging = false
    private var chargingMotionActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        track.backgroundColor = PowerPalette.cg(PowerPalette.track, in: self)
        track.borderColor = PowerPalette.cg(PowerPalette.border, in: self)
        track.borderWidth = 0.75
        layer?.addSublayer(track)

        fill.colors = [
            NSColor.systemGreen.withAlphaComponent(0.92).cgColor,
            NSColor(red: 0.03, green: 0.64, blue: 0.31, alpha: 0.78).cgColor
        ]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.masksToBounds = true
        layer?.addSublayer(fill)

        shimmer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.38).cgColor,
            NSColor.clear.cgColor
        ]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.5, 1]
        fill.addSublayer(shimmer)

        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        powerIcon.contentTintColor = .white
        powerIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        powerIcon.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        stateLabel.textColor = PowerPalette.secondary
        stateLabel.alignment = .right
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(powerIcon)
        addSubview(stateLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            powerIcon.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            powerIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            powerIcon.widthAnchor.constraint(equalToConstant: 16),
            powerIcon.heightAnchor.constraint(equalToConstant: 16),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: powerIcon.trailingAnchor, constant: 10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        track.frame = rect
        track.cornerRadius = rect.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFillFrame(in: rect)
        CATransaction.commit()
    }

    func update(_ snapshot: PowerFlowSnapshot) {
        let routing = PowerFlowRouting(snapshot: snapshot)
        level = min(max(snapshot.batteryLevel ?? 0, 0), 1)
        isCharging = snapshot.isCharging
        label.stringValue = snapshot.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "--%"
        powerIcon.image = NSImage(
            systemSymbolName: snapshot.isCharging
                ? "bolt.fill"
                : (snapshot.externalConnected ? "powerplug.fill" : "battery.50percent"),
            accessibilityDescription: nil
        )
        switch routing.mode {
        case .adapterCharging:
            stateLabel.stringValue = "外接电源 · 充电中"
        case .adapterDirect:
            stateLabel.stringValue = "适配器直供 · 电池待机"
        case .batteryOnly:
            stateLabel.stringValue = "正在使用电池"
        case .adapterWithBatteryAssist:
            stateLabel.stringValue = "混合供电 · 电池辅助"
        }
        fill.colors = level <= 0.2
            ? [NSColor.systemRed.cgColor, NSColor.systemOrange.cgColor]
            : [NSColor.systemGreen.withAlphaComponent(0.92).cgColor, NSColor.systemGreen.withAlphaComponent(0.68).cgColor]
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(.init(name: .easeInEaseOut))
        applyFillFrame(in: rect)
        CATransaction.commit()
        updateChargingMotion()
    }

    private func applyFillFrame(in rect: NSRect) {
        let width = max(rect.height, rect.width * level)
        fill.frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        fill.cornerRadius = rect.height / 2
        shimmer.frame = fill.bounds
    }

    private func updateChargingMotion() {
        let shouldAnimate = isCharging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate != chargingMotionActive else { return }
        chargingMotionActive = shouldAnimate
        powerIcon.layer?.removeAnimation(forKey: "boltPulse")
        shimmer.removeAnimation(forKey: "shimmer")
        shimmer.opacity = 0
        guard shouldAnimate else { return }

        shimmer.opacity = 1
        let slide = CABasicAnimation(keyPath: "locations")
        slide.fromValue = [-0.5, -0.25, 0]
        slide.toValue = [1, 1.25, 1.5]
        slide.duration = 1.55
        slide.repeatCount = .infinity
        shimmer.add(slide, forKey: "shimmer")

        powerIcon.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        powerIcon.layer?.add(pulse, forKey: "boltPulse")
    }
}

@MainActor
private final class PowerFlowCanvasView: NSView {
    private let source = PowerFlowNodeView(symbol: "powerplug.fill", accent: .systemYellow)
    private let system = PowerFlowNodeView(symbol: "laptopcomputer", accent: .systemBlue)
    private let battery = PowerFlowNodeView(symbol: "battery.75percent", accent: .systemGreen)
    private let cpu = PowerFlowNodeView(symbol: "cpu", accent: .systemCyan)
    private let gpu = PowerFlowNodeView(symbol: "display", accent: .systemIndigo)
    private let other = PowerFlowNodeView(symbol: "ellipsis", accent: .secondaryLabelColor)
    private var snapshot = PowerFlowSnapshot.placeholder
    private var displayLink: CADisplayLink?
    private var flowPhase: CGFloat = 0
    private var lastFrameTimestamp: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [source, system, battery, cpu, gpu, other].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopFlowAnimation()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsDisplay = true
            return
        }
        startFlowAnimation()
    }

    private func startFlowAnimation() {
        let link = displayLink(target: self, selector: #selector(stepFlowAnimation(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTimestamp = CACurrentMediaTime()
    }

    private func stopFlowAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = 0
    }

    @objc private func stepFlowAnimation(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTimestamp == 0 ? link.duration : max(now - lastFrameTimestamp, 0)
        lastFrameTimestamp = now
        let speed: CGFloat
        switch PowerFlowRouting(snapshot: snapshot).mode {
        case .adapterCharging: speed = 0.62
        case .adapterWithBatteryAssist: speed = 0.54
        case .adapterDirect: speed = 0.46
        case .batteryOnly: speed = 0.38
        }
        flowPhase = (flowPhase + speed * CGFloat(dt)).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        source.frame = NSRect(x: 0, y: 22, width: 72, height: 88)
        battery.frame = NSRect(x: 104, y: 74, width: 112, height: 48)
        system.frame = NSRect(x: 104, y: 12, width: 112, height: 48)
        cpu.frame = NSRect(x: 288, y: 92, width: 84, height: 29)
        gpu.frame = NSRect(x: 288, y: 52, width: 84, height: 29)
        other.frame = NSRect(x: 288, y: 12, width: 84, height: 29)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let routing = PowerFlowRouting(snapshot: snapshot)
        let systemPower = routing.systemLoadWatts
        let cpuPower = max(snapshot.cpuWatts ?? 0, 0)
        let gpuPower = max(snapshot.gpuWatts ?? 0, 0)
        let otherPower = max(snapshot.otherWatts ?? 0, 0)
        let loadTotal = max(cpuPower + gpuPower + otherPower, 0.1)

        // 场景一：外接适配器。适配器只连接它实际供电的对象；充电时另行
        // 分一路到电池，共同供电时电池反向汇入系统。
        if routing.adapterToBatteryWatts > 0 || routing.mode == .adapterCharging {
            let visualBatteryPower = max(routing.adapterToBatteryWatts, 0.1)
            let adapterTotal = max(routing.adapterOutputWatts, 0.1)
            let chargingPulse = 0.82 + 0.18 * sin(flowPhase * 2 * .pi)
            drawRibbon(
                from: NSPoint(x: source.frame.maxX, y: source.frame.maxY - 32),
                to: NSPoint(x: battery.frame.minX, y: battery.frame.midY),
                startHalfWidth: flowHalfWidth(value: visualBatteryPower, total: adapterTotal, minimum: 2.2, maximum: 8),
                endHalfWidth: flowHalfWidth(value: visualBatteryPower, total: adapterTotal, minimum: 2.2, maximum: 8),
                color: NSColor.systemGreen.withAlphaComponent(0.28 * chargingPulse),
                particleColor: NSColor.systemGreen,
                particleCount: 4,
                emphasized: true
            )
        }
        let adapterSystemRouteIsActive = routing.adapterToSystemWatts > 0.05 ||
            routing.mode == .adapterDirect || routing.mode == .adapterCharging
        if adapterSystemRouteIsActive {
            let adapterTotal = max(routing.adapterOutputWatts, 0.1)
            let visualSystemPower = max(routing.adapterToSystemWatts, 0.1)
            drawRibbon(
                from: NSPoint(x: source.frame.maxX, y: source.frame.minY + 33),
                to: NSPoint(x: system.frame.minX, y: system.frame.midY),
                startHalfWidth: flowHalfWidth(value: visualSystemPower, total: adapterTotal, minimum: 5, maximum: 18),
                endHalfWidth: flowHalfWidth(value: visualSystemPower, total: adapterTotal, minimum: 6, maximum: 20),
                color: NSColor.systemYellow.withAlphaComponent(0.29),
                particleColor: NSColor.systemYellow,
                particleCount: routing.mode == .adapterCharging ? 4 : 3,
                emphasized: routing.mode != .adapterCharging
            )
        }
        if routing.batteryToSystemWatts > 0.05 {
            drawVerticalRibbon(
                from: NSPoint(x: battery.frame.midX, y: battery.frame.minY),
                to: NSPoint(x: system.frame.midX, y: system.frame.maxY),
                halfWidth: flowHalfWidth(value: routing.batteryToSystemWatts, total: max(systemPower, 0.1), minimum: 2.2, maximum: 8),
                color: NSColor.systemGreen.withAlphaComponent(0.25),
                particleColor: NSColor.systemGreen,
                particleCount: 3,
                emphasized: true
            )
        }

        // 场景二：右侧三个负载必须从真正的供电起点出发。
        // 电池独立供电时从电池直接发出；所有外接电源场景从系统节点发出。
        let outputNode = routing.mode == .batteryOnly ? battery : system
        let cpuStart = NSPoint(x: outputNode.frame.maxX, y: outputNode.frame.maxY - 12)
        let gpuStart = NSPoint(x: outputNode.frame.maxX, y: outputNode.frame.midY)
        let otherStart = NSPoint(x: outputNode.frame.maxX, y: outputNode.frame.minY + 12)
        if cpuPower > 0.05 {
            drawRibbon(
                from: cpuStart,
                to: NSPoint(x: cpu.frame.minX, y: cpu.frame.midY),
                startHalfWidth: flowHalfWidth(value: cpuPower, total: loadTotal, minimum: 3, maximum: 11),
                endHalfWidth: flowHalfWidth(value: cpuPower, total: loadTotal, minimum: 3, maximum: 8),
                color: NSColor.systemCyan.withAlphaComponent(0.21),
                particleColor: NSColor.systemCyan,
                particleCount: 3
            )
        }
        if gpuPower > 0.05 {
            drawRibbon(
                from: gpuStart,
                to: NSPoint(x: gpu.frame.minX, y: gpu.frame.midY),
                startHalfWidth: flowHalfWidth(value: gpuPower, total: loadTotal, minimum: 3, maximum: 11),
                endHalfWidth: flowHalfWidth(value: gpuPower, total: loadTotal, minimum: 3, maximum: 8),
                color: NSColor.systemIndigo.withAlphaComponent(0.19),
                particleColor: NSColor.systemIndigo,
                particleCount: 3
            )
        }
        if otherPower > 0.05 {
            drawRibbon(
                from: otherStart,
                to: NSPoint(x: other.frame.minX, y: other.frame.midY),
                startHalfWidth: flowHalfWidth(value: otherPower, total: loadTotal, minimum: 3, maximum: 11),
                endHalfWidth: flowHalfWidth(value: otherPower, total: loadTotal, minimum: 3, maximum: 8),
                color: NSColor.systemGreen.withAlphaComponent(0.18),
                particleColor: NSColor.systemGreen,
                particleCount: 3
            )
        }
    }

    private func drawVerticalRibbon(
        from start: NSPoint,
        to end: NSPoint,
        halfWidth: CGFloat,
        color: NSColor,
        particleColor: NSColor,
        particleCount: Int,
        emphasized: Bool
    ) {
        let rect = NSRect(
            x: start.x - halfWidth,
            y: min(start.y, end.y),
            width: halfWidth * 2,
            height: abs(end.y - start.y)
        )
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: halfWidth,
            yRadius: halfWidth
        )
        color.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(emphasized ? 0.22 : 0.12).setStroke()
        path.lineWidth = emphasized ? 0.9 : 0.7
        path.stroke()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let count = reduceMotion ? 1 : max(particleCount, 1)
        for index in 0..<count {
            let progress = reduceMotion
                ? 0.5
                : PowerFlowGeometry.particleOffset(phase: flowPhase, index: index, count: count)
            let opacity = PowerFlowGeometry.particleOpacity(progress: progress)
            guard opacity > 0.04 else { continue }
            let t = 0.08 + 0.84 * progress
            let point = NSPoint(
                x: start.x,
                y: start.y + (end.y - start.y) * t
            )
            drawParticle(
                at: point,
                opacity: opacity,
                color: particleColor,
                emphasized: emphasized
            )
        }
    }

    private func flowHalfWidth(value: Double, total: Double, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard total > 0 else { return minimum }
        let ratio = CGFloat(min(max(value / total, 0), 1))
        return minimum + (maximum - minimum) * sqrt(ratio)
    }

    private func drawRibbon(
        from start: NSPoint,
        to end: NSPoint,
        startHalfWidth: CGFloat,
        endHalfWidth: CGFloat,
        color: NSColor,
        particleColor: NSColor,
        particleCount: Int,
        emphasized: Bool = false
    ) {
        let controlX = start.x + (end.x - start.x) * 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: start.x, y: start.y + startHalfWidth))
        path.curve(
            to: NSPoint(x: end.x, y: end.y + endHalfWidth),
            controlPoint1: NSPoint(x: controlX, y: start.y + startHalfWidth),
            controlPoint2: NSPoint(x: controlX, y: end.y + endHalfWidth)
        )
        path.line(to: NSPoint(x: end.x, y: end.y - endHalfWidth))
        path.curve(
            to: NSPoint(x: start.x, y: start.y - startHalfWidth),
            controlPoint1: NSPoint(x: controlX, y: end.y - endHalfWidth),
            controlPoint2: NSPoint(x: controlX, y: start.y - startHalfWidth)
        )
        path.close()
        color.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(emphasized ? 0.22 : 0.12).setStroke()
        path.lineWidth = emphasized ? 0.9 : 0.7
        path.stroke()

        let control1 = CGPoint(x: controlX, y: start.y)
        let control2 = CGPoint(x: controlX, y: end.y)
        let startPoint = CGPoint(x: start.x, y: start.y)
        let endPoint = CGPoint(x: end.x, y: end.y)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let count = reduceMotion ? 1 : max(particleCount, 1)
        for index in 0..<count {
            let progress = reduceMotion
                ? 0.5
                : PowerFlowGeometry.particleOffset(phase: flowPhase, index: index, count: count)
            let opacity = PowerFlowGeometry.particleOpacity(progress: progress)
            guard opacity > 0.04 else { continue }
            let t = 0.08 + 0.84 * progress
            let point = PowerFlowGeometry.cubicPoint(
                t: t,
                start: startPoint,
                control1: control1,
                control2: control2,
                end: endPoint
            )
            drawParticle(
                at: point,
                opacity: opacity,
                color: particleColor,
                emphasized: emphasized
            )
        }
    }

    private func drawParticle(
        at point: NSPoint,
        opacity: CGFloat,
        color: NSColor,
        emphasized: Bool
    ) {
        let radius: CGFloat = (emphasized ? 3.1 : 2.4) + 1.1 * opacity
        let glow = NSBezierPath(
            ovalIn: NSRect(
                x: point.x - radius * 2.1,
                y: point.y - radius * 2.1,
                width: radius * 4.2,
                height: radius * 4.2
            )
        )
        color.withAlphaComponent(0.16 * opacity).setFill()
        glow.fill()
        let core = NSBezierPath(
            ovalIn: NSRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        NSColor.white.withAlphaComponent((emphasized ? 0.78 : 0.58) * opacity).setFill()
        core.fill()
    }

    func update(_ snapshot: PowerFlowSnapshot) {
        self.snapshot = snapshot
        let routing = PowerFlowRouting(snapshot: snapshot)
        let actualInput: Double?
        if snapshot.externalConnected {
            actualInput = routing.adapterOutputWatts > 0
                ? routing.adapterOutputWatts
                : snapshot.inputWatts
        } else {
            actualInput = nil
        }
        source.update(
            title: snapshot.externalConnected ? "适配器" : "适配器未连接",
            value: snapshot.externalConnected ? watts(actualInput) : "--"
        )
        system.update(title: "系统负载", value: watts(routing.systemLoadWatts))
        let batteryValue: String
        switch routing.mode {
        case .adapterCharging:
            batteryValue = routing.adapterToBatteryWatts > 0
                ? String(format: "+%.1f W", routing.adapterToBatteryWatts)
                : "充电中"
        case .adapterDirect:
            batteryValue = "待机"
        case .batteryOnly:
            batteryValue = routing.batteryToLoadsWatts > 0
                ? String(format: "-%.1f W", routing.batteryToLoadsWatts)
                : "供电中"
        case .adapterWithBatteryAssist:
            batteryValue = String(format: "辅助 %.1f W", routing.batteryToSystemWatts)
        }
        battery.update(title: "电池", value: batteryValue)
        cpu.update(title: "CPU", value: watts(snapshot.cpuWatts))
        gpu.update(title: "GPU", value: watts(snapshot.gpuWatts))
        other.update(title: "其他", value: watts(snapshot.otherWatts))
        source.setChargingPulse(snapshot.externalConnected && routing.adapterOutputWatts > 0)
        battery.setChargingPulse(
            routing.mode == .adapterCharging ||
            routing.mode == .batteryOnly ||
            routing.mode == .adapterWithBatteryAssist
        )
        source.setActive(snapshot.externalConnected)
        system.setActive(routing.mode != .batteryOnly)
        battery.setActive(routing.mode != .adapterDirect)
        cpu.setActive(powerIsAvailable(snapshot.cpuWatts))
        gpu.setActive(powerIsAvailable(snapshot.gpuWatts))
        other.setActive(powerIsAvailable(snapshot.otherWatts))
        needsDisplay = true
    }

    private func powerIsAvailable(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && value > 0.05
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "-- W"
    }
}

@MainActor
private final class PowerFlowNodeView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let accent: NSColor
    private var pulsing = false
    private var active = true

    init(symbol: String, accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        applyMenuChrome()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowOffset = .zero

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.alignment = .center

        titleLabel.font = .systemFont(ofSize: 8.5, weight: .medium)
        titleLabel.textColor = PowerPalette.tertiary
        titleLabel.alignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        valueLabel.textColor = PowerPalette.primary
        valueLabel.alignment = .center

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMenuChrome()
    }

    private func applyMenuChrome() {
        layer?.backgroundColor = PowerPalette.cg(PowerPalette.surface, in: self)
        layer?.borderColor = PowerPalette.cg(PowerPalette.border, in: self)
        alphaValue = active ? 1 : 0.34
    }

    override func layout() {
        super.layout()
        let compact = bounds.height < 56
        if compact {
            icon.frame = NSRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
            titleLabel.frame = NSRect(x: 24, y: bounds.midY - 2, width: 27, height: 11)
            valueLabel.frame = NSRect(x: 49, y: bounds.midY - 4, width: bounds.width - 54, height: 13)
        } else {
            icon.frame = NSRect(x: (bounds.width - 22) / 2, y: bounds.height - 29, width: 22, height: 20)
            titleLabel.frame = NSRect(x: 5, y: 22, width: bounds.width - 10, height: 12)
            valueLabel.frame = NSRect(x: 4, y: 7, width: bounds.width - 8, height: 15)
        }
    }

    func update(title: String, value: String) {
        titleLabel.stringValue = title
        valueLabel.stringValue = value
        setAccessibilityLabel(title)
        setAccessibilityValue(value)
    }

    func setChargingPulse(_ enabled: Bool) {
        let shouldPulse = enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldPulse != pulsing else { return }
        pulsing = shouldPulse
        layer?.removeAnimation(forKey: "chargePulse")
        guard shouldPulse else {
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
            return
        }
        layer?.shadowColor = accent.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 10
        let anim = CABasicAnimation(keyPath: "shadowOpacity")
        anim.fromValue = 0.12
        anim.toValue = 0.48
        anim.duration = 1.05
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(anim, forKey: "chargePulse")
    }

    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        alphaValue = enabled ? 1 : 0.34
        if !enabled {
            setChargingPulse(false)
        }
    }
}

@MainActor
private final class PowerDetailsCardView: LiquidGlassCardView {
    private let temperature = PowerDetailRow(symbol: "thermometer.medium", title: "电池温度")
    private let fullTime = PowerDetailRow(symbol: "clock", title: "充满时间")
    private let systemPower = PowerDetailRow(symbol: "laptopcomputer", title: "系统功率")
    private let lowPower = PowerDetailRow(symbol: "battery.25percent", title: "低电量模式")
    private let adapter = PowerDetailRow(symbol: "powerplug.fill", title: "输入功率 / 能力")

    override init(frame: NSRect) {
        super.init(frame: frame)

        let firstSeparator = separator()
        let secondSeparator = separator()
        let stack = NSStackView(views: [temperature, fullTime, firstSeparator, systemPower, lowPower, secondSeparator, adapter])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
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

    func update(_ snapshot: PowerFlowSnapshot) {
        let routing = PowerFlowRouting(snapshot: snapshot)
        temperature.value = snapshot.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "--"

        switch routing.mode {
        case .adapterCharging:
            if let minutes = snapshot.timeToFullMinutes {
                fullTime.value = "\(minutes / 60)小时\(minutes % 60)分钟"
            } else {
                fullTime.value = "计算中"
            }
        case .adapterDirect:
            fullTime.value = "充电已暂停"
        case .batteryOnly:
            fullTime.value = "未连接电源"
        case .adapterWithBatteryAssist:
            fullTime.value = "电池正在辅助供电"
        }

        systemPower.value = watts(routing.systemLoadWatts)
        lowPower.value = snapshot.lowPowerMode ? "已开启" : "已关闭"

        let actualInput: Double?
        if snapshot.externalConnected {
            actualInput = routing.adapterOutputWatts > 0
                ? routing.adapterOutputWatts
                : snapshot.inputWatts
        } else {
            actualInput = nil
        }
        if let input = actualInput, let maximum = snapshot.adapterWatts {
            adapter.value = "\(String(format: "%.1f W", input)) / \(Int(maximum.rounded())) W"
        } else {
            adapter.value = watts(actualInput ?? snapshot.adapterWatts)
        }
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "--"
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.45)
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}

@MainActor
private final class PowerDetailRow: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "--")

    var value: String {
        get { valueLabel.stringValue }
        set {
            valueLabel.stringValue = newValue
            setAccessibilityValue(newValue)
        }
    }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 27).isActive = true

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = PowerPalette.secondary
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = PowerPalette.secondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        valueLabel.textColor = PowerPalette.primary
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])

        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
