import AppKit

@MainActor
final class DisplayConsoleDashboardView: NSView {
    var onHeightChanged: (() -> Void)?
    var isPresented = false

    private let io: DisplayConsoleIO
    private let stack = FullWidthStackView()
    private let topology = NSTextField(wrappingLabelWithString: "正在读取屏幕…")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let layouts = NSSegmentedControl(labels: ScreenPageLayout.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let trialRow = NSStackView()
    private let countdown = NSTextField(labelWithString: "")
    private let keep = NSButton(title: "保留", target: nil, action: nil)
    private let revert = NSButton(title: "还原", target: nil, action: nil)
    private let brightnessCard = LiquidGlassCardView()
    private let externalRow = NSStackView()
    private let builtinRow = NSStackView()
    private let autoRow = NSStackView()
    private let externalSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let builtinSlider = NSSlider(value: 50, minValue: 2, maxValue: 100, target: nil, action: nil)
    private let externalValue = NSTextField(labelWithString: "")
    private let builtinValue = NSTextField(labelWithString: "")
    private let automatic = NSSwitch()
    private let powerCard = LiquidGlassCardView()
    private let powerButton = NSButton(title: "熄屏", target: nil, action: nil)
    private let powerHint = NSTextField(wrappingLabelWithString: "")
    private let recover = NSButton(title: "恢复内置屏", target: nil, action: nil)
    private var current = DisplayConsoleSnapshot()
    private var screenNames: [ConnectedDisplay] = []
    private var hasSnapshot = false
    private var trial: ScreenLayoutTrial?
    private var timer: Timer?
    private var expiryChecks = 0
    private var nextExpiryCheck = Date.distantPast
    private var generation = 0
    private var topologyGeneration = 0
    private var reading = false
    private var refreshRequested = false
    private var busy = false
    private var startingBlank: UUID?
    private var lastBlankRequest: UUID?

    override convenience init(frame: NSRect) {
        self.init(io: DisplayConsoleIO())
        NotificationCenter.default.addObserver(self, selector: #selector(physicalChanged), name: DisplaySafetyPolicy.physicalScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(self, selector: #selector(willSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, DisplaySafetyPolicy.physicalScreensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(physicalChanged), name: name, object: nil)
        }
        IntegratedHotCornerController.shared.onStateChanged = { [weak self] in
            if self?.isPresented == true { self?.refreshAll() }
        }
    }

    init(io: DisplayConsoleIO) {
        self.io = io
        super.init(frame: .zero)
        buildPage()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 376, height: stack.fittingSize.height) }

    private func buildPage() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        pin(stack, to: self)
        widthAnchor.constraint(equalToConstant: 376).isActive = true

        let display = body(in: LiquidGlassCardView())
        let settings = NSButton(title: "系统显示器设置", target: self, action: #selector(openSettings))
        settings.controlSize = .small
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新屏幕状态")!, target: self, action: #selector(refreshAll))
        refresh.isBordered = false
        refresh.toolTip = "刷新屏幕状态"
        display.addArrangedSubview(row([heading("当前显示"), NSView(), settings, refresh]))
        topology.font = .systemFont(ofSize: 12)
        display.addArrangedSubview(topology)
        layouts.target = self
        layouts.action = #selector(changeLayout)
        layouts.segmentDistribution = .fillEqually
        layouts.setAccessibilityLabel("显示布局")
        display.addArrangedSubview(layouts)
        keep.target = self
        keep.action = #selector(keepLayout)
        revert.target = self
        revert.action = #selector(revertLayout)
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countdown.textColor = .systemOrange
        configure(trialRow, views: [countdown, NSView(), revert, keep])
        display.addArrangedSubview(trialRow)
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        display.addArrangedSubview(feedback)

        let brightness = body(in: brightnessCard)
        brightness.addArrangedSubview(heading("亮度"))
        configureBrightness(externalRow, title: "AOC", slider: externalSlider, value: externalValue)
        configureBrightness(builtinRow, title: "内置屏", slider: builtinSlider, value: builtinValue)
        automatic.controlSize = .small
        automatic.setAccessibilityLabel("外屏自动亮度")
        automatic.target = self
        automatic.action = #selector(changeAutomatic)
        configure(autoRow, views: [NSTextField(labelWithString: "外屏自动亮度"), NSView(), automatic])
        for item in [externalRow, builtinRow, autoRow] { brightness.addArrangedSubview(item) }

        let power = body(in: powerCard)
        powerButton.target = self
        powerButton.action = #selector(changePower)
        recover.target = self
        recover.action = #selector(recoverBuiltin)
        power.addArrangedSubview(row([heading("屏幕电源"), NSView(), recover, powerButton]))
        powerHint.font = .systemFont(ofSize: 11)
        powerHint.textColor = .secondaryLabelColor
        power.addArrangedSubview(powerHint)
    }

    private func pin(_ child: NSView, to parent: NSView) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                                     child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                                     child.topAnchor.constraint(equalTo: parent.topAnchor),
                                     child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }

    private func body(in card: LiquidGlassCardView) -> NSStackView {
        let content = FullWidthStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        stack.addArrangedSubview(card)
        pin(content, to: card)
        return content
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func configure(_ row: NSStackView, views: [NSView]) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        views.forEach(row.addArrangedSubview)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let result = NSStackView()
        configure(result, views: views)
        return result
    }

    private func configureBrightness(_ row: NSStackView, title: String, slider: NSSlider, value: NSTextField) {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 43).isActive = true
        slider.setAccessibilityLabel("\(title)亮度")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(changeBrightness(_:))
        configure(row, views: [label, slider, value])
    }

    @objc func physicalChanged() { topologyChanged(refresh: isPresented) }
    @objc private func willSleep() { topologyChanged(refresh: false) }

    func topologyChanged(refresh: Bool = true) {
        topologyGeneration += 1
        generation += 1
        refreshRequested = false
        current = DisplayConsoleSnapshot()
        hasSnapshot = false
        screenNames.removeAll()
        feedback.stringValue = ""
        render()
        if refresh { refreshAll() }
    }

    @objc func refreshAll() {
        generation += 1
        refreshRequested = true
        guard !reading, !busy else { return }
        reading = true
        render()
        Task {
            while refreshRequested && !busy {
                refreshRequested = false
                let request = generation
                let result = await Task.detached(priority: .userInitiated) { [io] in io.snapshot() }.value
                if request == generation {
                    current = result
                    hasSnapshot = true
                    screenNames = io.connected()
                    if result.blank.needsRelease { startingBlank = nil }
                    if result.failure == nil { setTrial(result.trial) }
                }
            }
            reading = false
            render()
        }
    }

    private func render() {
        let available = !busy && !reading && startingBlank == nil
        let active = current.online
        if let failure = current.failure {
            topology.stringValue = failure
        } else if current.blank.needsRelease {
            topology.stringValue = current.blank == .active ? "硬件熄屏中" : "背光等待恢复"
        } else if !active.isEmpty || !screenNames.isEmpty {
            let panels = active.map { panel in
                let name = screenNames.first { $0.id == panel.id }?.name ?? panel.displayTitle
                let title = panel.builtin || panel.isAOC ? panel.displayTitle : name
                let mode = panel.asleep == true ? "休眠中" : panel.modeSummary
                return "\(title)  ·  \(mode)"
            }
            let otherScreens = screenNames.filter { screen in !active.contains { $0.id == screen.id } }
            topology.stringValue = (panels + otherScreens.map(\.name)).joined(separator: "\n")
        } else {
            topology.stringValue = hasSnapshot ? "当前没有在线的屏幕" : "正在读取屏幕…"
        }
        layouts.isHidden = current.aoc == nil || !current.knownScreens || current.blank.needsRelease
        layouts.selectedSegment = ScreenPageLayout.allCases.firstIndex { $0 == current.liveLayout } ?? -1
        for (index, layout) in ScreenPageLayout.allCases.enumerated() {
            layouts.setEnabled(available && trial == nil && current.canApply(layout), forSegment: index)
        }
        trialRow.isHidden = trial == nil
        keep.isEnabled = available && current.blank == .idle && (trial?.expires.timeIntervalSinceNow ?? 0) > 0
        revert.isEnabled = available && current.blank == .idle && trial != nil
        feedback.isHidden = feedback.stringValue.isEmpty
        externalRow.isHidden = current.aoc == nil
        builtinRow.isHidden = current.builtin == nil
        autoRow.isHidden = externalRow.isHidden
        brightnessCard.isHidden = current.blank.needsRelease || (externalRow.isHidden && builtinRow.isHidden)
        let auto = io.autoEnabled()
        automatic.state = auto ? .on : .off
        let editable = available && trial == nil && current.canEdit
        automatic.isEnabled = available && (auto || (editable && current.externalBrightness != nil))
        externalSlider.isEnabled = editable && !auto && current.externalBrightness != nil
        externalSlider.toolTip = auto ? "关闭外屏自动亮度后可手动调节" : nil
        builtinSlider.isEnabled = editable && current.builtinBrightness != nil
        for (slider, value, label) in [(externalSlider, current.externalBrightness, externalValue),
                                       (builtinSlider, current.builtinBrightness, builtinValue)] {
            if let value { slider.integerValue = value }
            label.stringValue = value.map { "\($0)%" } ?? "不可读"
        }
        recover.isHidden = !current.mayRecoverBuiltin
        recover.isEnabled = editable && current.mayRecoverBuiltin
        powerButton.title = current.blank.needsRelease ? "恢复背光" : "熄屏"
        let supportsPower = !active.isEmpty && current.knownScreens
        powerCard.isHidden = !hasSnapshot || !(supportsPower || current.blank.needsRelease || current.mayRecoverBuiltin)
        powerButton.isEnabled = (available && trial == nil && current.canBlank) || (!busy && !reading && current.blank.needsRelease)
        switch current.blank {
        case .unknown: powerHint.stringValue = reading || generation == 0 ? "" : "熄屏状态未知，请刷新重试。"
        case .active, .pendingRestore: powerHint.stringValue = "可用 ⌘⌥⇧O 恢复背光。外屏可能需要按实体电源键。"
        case .idle:
            if !current.knownScreens { powerHint.stringValue = "当前外接显示器不支持硬件熄屏。" }
            else if !current.lidOpen { powerHint.stringValue = "打开电脑上盖后可使用硬件熄屏。" }
            else { powerHint.stringValue = current.aoc != nil ? "熄屏后，AOC 可能需要按实体电源键重新开启。" : "" }
        }
        powerHint.isHidden = powerHint.stringValue.isEmpty
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func runOperation(_ progress: String, work: @escaping @MainActor () async -> String) {
        guard !busy, !reading else { return }
        busy = true
        feedback.stringValue = progress
        render()
        Task {
            let result = await work()
            feedback.stringValue = result
            busy = false
            refreshAll()
        }
    }

    @objc private func changeBrightness(_ sender: NSSlider) {
        let target = sender === externalSlider ? current.aoc : current.builtin
        guard sender.isEnabled, let target else { return }
        let value = Int(sender.doubleValue.rounded())
        runOperation("正在调节亮度…") { [io] in
            let verified = await Task.detached { io.setBrightness(value, on: target) }.value
            return verified ? "" : "亮度未能确认，已重新读取。"
        }
    }

    @objc private func changeAutomatic() {
        guard automatic.isEnabled else { return }
        let enabled = automatic.state == .on
        let target = current.aoc?.id
        let epoch = topologyGeneration
        runOperation("正在更新自动亮度…") { [self] in
            if enabled {
                let live = await Task.detached { [io] in io.snapshot(readBrightness: false) }.value
                guard topologyGeneration == epoch, live.canEdit, let panel = live.aoc,
                      panel.isReady, panel.id == target else { return "外屏状态已变化，请重试。" }
            }
            return await io.setAuto(enabled)
        }
    }

    @objc private func changeLayout() {
        let index = layouts.selectedSegment
        guard ScreenPageLayout.allCases.indices.contains(index), layouts.isEnabled(forSegment: index) else { render(); return }
        let layout = ScreenPageLayout.allCases[index]
        guard layout != current.liveLayout || layout.rawValue != current.savedLayout else { return }
        let target = current.aoc?.id
        let epoch = topologyGeneration
        runOperation("正在切换布局…") { [self] in
            let live = await Task.detached { [io] in io.snapshot(readBrightness: false) }.value
            guard topologyGeneration == epoch, live.canApply(layout), live.aoc?.id == target else { return "屏幕状态已变化，请重新选择布局。" }
            let reply = await Task.detached { [io] in io.command("DisplayManager", ["guarded-preset", layout.rawValue], timeout: 15) }.value
            guard reply.succeeded else { return "切换失败：\(reply.failure)" }
            guard let trial = ScreenLayoutTrial(reply.json, key: "token") else { return "未读到布局确认记录，请查看当前状态。" }
            setTrial(trial)
            return ""
        }
    }

    private func setTrial(_ value: ScreenLayoutTrial?) {
        guard trial != value else { return }
        trial = value
        timer?.invalidate()
        expiryChecks = 0
        nextExpiryCheck = .distantPast
        guard value != nil else { timer = nil; return }
        tick()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let trial else { return }
        let remaining = Int(ceil(trial.expires.timeIntervalSinceNow))
        countdown.stringValue = remaining > 0 ? "\(remaining) 秒后自动还原" : "确认已到期，等待还原"
        if remaining <= 0 {
            keep.isEnabled = false
            if expiryChecks >= 12 {
                countdown.stringValue = "尚未确认还原，可重试"
                timer?.invalidate()
            } else if !reading && !busy && Date() >= nextExpiryCheck {
                expiryChecks += 1
                nextExpiryCheck = Date().addingTimeInterval(1)
                refreshAll()
            }
        }
    }

    @objc private func keepLayout() { finishLayout(keeping: true) }
    @objc private func revertLayout() { finishLayout(keeping: false) }

    private func finishLayout(keeping: Bool) {
        guard (keeping ? keep : revert).isEnabled, let trial else { return }
        runOperation(keeping ? "正在保留布局…" : "正在还原布局…") { [io] in
            let live = await Task.detached { io.snapshot(readBrightness: false) }.value
            guard live.blank == .idle, live.trial == trial, !keeping || trial.expires > Date() else {
                return "布局确认状态已变化，请查看当前布局。"
            }
            let reply = await Task.detached { io.command("DisplayManager", [keeping ? "confirm" : "rollback-now", trial.token], timeout: 12) }.value
            return reply.succeeded ? (keeping ? "已保留布局" : "已还原布局") : "操作失败：\(reply.failure)"
        }
    }

    @objc private func changePower() {
        guard powerButton.isEnabled else { return }
        let releasing = current.blank.needsRelease
        let epoch = topologyGeneration
        runOperation(releasing ? "正在恢复背光…" : "正在请求熄屏…") { [self] in
            if releasing {
                return await Task.detached { [io] in
                    guard io.blankState().needsRelease else { return "熄屏状态已变化。" }
                    let reply = io.command("ScreenBlank", ["--release"], timeout: 6)
                    return reply.code == 0 && io.blankState() == .idle ? "已恢复背光" : "背光尚未确认恢复，可刷新后重试。"
                }.value
            }
            let live = await Task.detached { [io] in io.snapshot(readBrightness: false) }.value
            guard topologyGeneration == epoch, live.canBlank, live.online.map(\.id).sorted() == current.online.map(\.id).sorted(),
                  let path = io.helperPath("ScreenBlank") else { return "屏幕状态已变化，熄屏请求已取消。" }
            return startBlank(path)
        }
    }

    private func startBlank(_ path: String) -> String {
        let request = UUID()
        startingBlank = request
        do {
            try io.startBlank(path) { [weak self] code in
                Task { @MainActor in
                    guard let self, self.lastBlankRequest == request else { return }
                    self.startingBlank = nil
                    if code != 0 { self.feedback.stringValue = "硬件熄屏未完成，请刷新重试。" }
                    self.refreshAll()
                }
            }
        } catch {
            startingBlank = nil
            return "熄屏未启动：\(error.localizedDescription)"
        }
        lastBlankRequest = request
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(200))
                guard startingBlank == request else { return }
                let state = await Task.detached { [io] in io.blankState() }.value
                guard startingBlank == request else { return }
                if state.needsRelease {
                    startingBlank = nil
                    refreshAll()
                    return
                }
            }
            if startingBlank == request {
                feedback.stringValue = "正在等待硬件熄屏会话，可刷新查看状态。"
                refreshAll()
            }
        }
        return ""
    }

    @objc private func recoverBuiltin() {
        guard recover.isEnabled else { return }
        runOperation("正在恢复内置屏…") { [io] in
            await Task.detached {
                guard io.snapshot(readBrightness: false).mayRecoverBuiltin else { return "内置屏恢复条件已变化。" }
                let reply = io.command("DisplayManager", ["safety-recover"], timeout: 10)
                return reply.succeeded && reply.json?["skipped"] == nil ? "已恢复内置屏" : "本次未恢复内置屏，请查看当前状态。"
            }.value
        }
    }

    @objc private func openSettings() {
        if !io.openSettings() {
            feedback.stringValue = "无法打开系统显示器设置。"
            render()
        }
    }
}
