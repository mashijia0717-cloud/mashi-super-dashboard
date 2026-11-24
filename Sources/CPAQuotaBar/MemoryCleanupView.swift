import AppKit
import Darwin
import Foundation

enum CleanupPageMode: String, CaseIterable {
    case memory
    case disk

    var title: String {
        switch self {
        case .memory: "内存透视与清理"
        case .disk: "磁盘缓存清理"
        }
    }
}

@MainActor
final class MemorySegmentedBarView: NSView {
    struct Segment {
        let fraction: Double
        let color: NSColor
    }

    var segments: [Segment] = [] {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard rect.width > 4, rect.height > 2 else { return }
        let radius = rect.height / 2
        let clipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        rect.fill()

        var cursorX: CGFloat = 0
        for seg in segments where seg.fraction.isFinite && seg.fraction > 0 {
            let width = min(rect.width - cursorX, rect.width * CGFloat(min(seg.fraction, 1)))
            guard width > 0 else { continue }
            seg.color.setFill()
            NSRect(x: cursorX, y: 0, width: width, height: rect.height).fill()
            cursorX += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class MemoryCleanupDashboardView: NSView {
    var onRefreshRequested: (() -> Void)?
    var onSmartClean: (([RunningAppIdentity]) -> Void)?
    var onTerminateSingleApp: ((RunningApp) -> Void)?
    var onHeightChanged: (() -> Void)?

    private let rootStack = FullWidthStackView()
    private let pressureBadge = NSTextField(labelWithString: "检测中")
    private let headlineUsedLabel = NSTextField(labelWithString: "-- GB")
    private let headlineAvailLabel = NSTextField(labelWithString: "正在采样物理内存…")
    private let compositionBar = MemorySegmentedBarView()
    private let resultBanner = NSTextField(wrappingLabelWithString: "")

    private let appMetricValue = NSTextField(labelWithString: "--")
    private let wiredMetricValue = NSTextField(labelWithString: "--")
    private let compressedMetricValue = NSTextField(labelWithString: "--")
    private let compressedSubLabel = NSTextField(labelWithString: "内存压缩器实时折叠非活跃页")
    private let cachedMetricValue = NSTextField(labelWithString: "--")

    private let swapSummaryValue = NSTextField(labelWithString: "--")
    private let swapActivityValue = NSTextField(labelWithString: "--")
    private let vmPagesValue = NSTextField(labelWithString: "--")

    private let selectIdleButton = NSButton(title: "勾选后台大户", target: nil, action: nil)
    private let cleanActionButton = NSButton(title: "一键智能释放", target: nil, action: nil)
    private let cleanSpinner = NSProgressIndicator()
    private let appsStack = FullWidthStackView()
    private let appsEmptyLabel = NSTextField(labelWithString: "正在读取运行中应用的物理内存占用…")

    private var currentApps: [RunningApp] = []
    private var currentTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    private var selectedIdentities = Set<RunningAppIdentity>()
    private var isCleaning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: 376, height: rootStack.fittingSize.height)
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        rootStack.addArrangedSubview(makeOverviewCard())
        rootStack.addArrangedSubview(makeBreakdownCard())
        rootStack.addArrangedSubview(makeSwapCard())
        rootStack.addArrangedSubview(makeAppsCleanupCard())

        let footNote = NSTextField(
            wrappingLabelWithString: "排行仅含应用主进程，优先读取物理足迹；读取失败时标注驻留量。无勾选时仅整理仪表盘自身缓存与空闲分配，勾选后向应用请求正常退出，可能需要先保存文档。"
        )
        footNote.font = .systemFont(ofSize: 10)
        footNote.textColor = .secondaryLabelColor
        footNote.maximumNumberOfLines = 0
        rootStack.addArrangedSubview(footNote)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 376)
        ])
    }

    private func makeOverviewCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardBodyStack(in: card)

        let titleLabel = NSTextField(labelWithString: "物理内存总览")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        pressureBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        pressureBadge.wantsLayer = true
        pressureBadge.layer?.cornerRadius = 5
        pressureBadge.alignment = .center

        let topRow = NSStackView(views: [titleLabel, NSView(), pressureBadge])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        stack.addArrangedSubview(topRow)

        headlineUsedLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .bold)
        headlineAvailLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        headlineAvailLabel.textColor = .secondaryLabelColor

        let heroRow = NSStackView(views: [headlineUsedLabel, headlineAvailLabel])
        heroRow.orientation = .vertical
        heroRow.alignment = .leading
        heroRow.spacing = 3
        stack.addArrangedSubview(heroRow)

        stack.addArrangedSubview(compositionBar)
        compositionBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        let legendRow = NSStackView(views: [
            legendDot(color: .systemBlue, text: "应用"),
            legendDot(color: .systemOrange, text: "联动"),
            legendDot(color: .systemPurple, text: "已压缩"),
            legendDot(color: .systemTeal, text: "可回收缓存"),
            NSView()
        ])
        legendRow.orientation = .horizontal
        legendRow.spacing = 10
        stack.addArrangedSubview(legendRow)
        let compositionNote = NSTextField(wrappingLabelWithString: "已用 = 应用估算 + 联动 + 压缩；可用估算包含可回收缓存。灰色为剩余空间，Swap 另计。")
        compositionNote.font = .systemFont(ofSize: 10)
        compositionNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(compositionNote)

        resultBanner.font = .systemFont(ofSize: 11, weight: .medium)
        resultBanner.textColor = .systemGreen
        resultBanner.isHidden = true
        stack.addArrangedSubview(resultBanner)

        return card
    }

    private func makeBreakdownCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardBodyStack(in: card)

        let header = NSTextField(labelWithString: "四维内存构成明细")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(
            breakdownRow(
                color: .systemBlue,
                title: "应用内存（估算）",
                subtitle: "匿名页扣除可清除页；不等于下方应用足迹之和",
                valueField: appMetricValue
            )
        )
        stack.addArrangedSubview(thinDivider())
        stack.addArrangedSubview(
            breakdownRow(
                color: .systemOrange,
                title: "联动内存（Wired）",
                subtitle: "必须驻留的系统页；并非完整 GPU 显存统计",
                valueField: wiredMetricValue
            )
        )
        stack.addArrangedSubview(thinDivider())
        stack.addArrangedSubview(
            breakdownRow(
                color: .systemPurple,
                title: "已压缩内存",
                subtitleField: compressedSubLabel,
                valueField: compressedMetricValue
            )
        )
        stack.addArrangedSubview(thinDivider())
        stack.addArrangedSubview(
            breakdownRow(
                color: .systemTeal,
                title: "文件与可清除缓存",
                subtitle: "已包含在可用估算内；按需回收，不必强制清空",
                valueField: cachedMetricValue
            )
        )
        return card
    }

    private func makeSwapCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardBodyStack(in: card)

        let header = NSTextField(labelWithString: "Swap 交换内存与读写诊断")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(kvRow(key: "Swap 已用 / 已分配", valueField: swapSummaryValue))
        stack.addArrangedSubview(kvRow(key: "实时磁盘交换状态", valueField: swapActivityValue))
        stack.addArrangedSubview(kvRow(key: "累计分页读入 / 写出", valueField: vmPagesValue))
        vmPagesValue.toolTip = "系统启动以来的分页计数，也包括文件分页，不能等同于 Swap 读写。"
        swapSummaryValue.toolTip = "已分配交换空间会由系统动态调整，不是磁盘容量上限。"
        return card
    }

    private func makeAppsCleanupCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardBodyStack(in: card)

        let header = NSTextField(labelWithString: "应用主进程排行 · 前 12 项")
        header.font = .systemFont(ofSize: 12, weight: .semibold)

        let refreshBtn = NSButton()
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新内存")
        refreshBtn.imagePosition = .imageOnly
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.contentTintColor = .secondaryLabelColor
        refreshBtn.toolTip = "立即重新采样内存与应用占用"
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshTapped)

        let headerRow = NSStackView(views: [header, NSView(), refreshBtn])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        stack.addArrangedSubview(headerRow)

        selectIdleButton.controlSize = .small
        selectIdleButton.bezelStyle = .rounded
        selectIdleButton.target = self
        selectIdleButton.action = #selector(toggleSelectIdleApps)
        selectIdleButton.toolTip = "勾选非当前前台且占用至少 350 MB 的应用；后台不代表没有任务。"

        cleanSpinner.style = .spinning
        cleanSpinner.controlSize = .small
        cleanSpinner.isHidden = true

        cleanActionButton.controlSize = .small
        cleanActionButton.bezelStyle = .rounded
        if #available(macOS 26.0, *) {
            cleanActionButton.bezelStyle = .glass
        }
        cleanActionButton.target = self
        cleanActionButton.action = #selector(runSmartClean)

        let actionBar = NSStackView(views: [selectIdleButton, NSView(), cleanSpinner, cleanActionButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 6
        stack.addArrangedSubview(actionBar)
        let trendNote = NSTextField(wrappingLabelWithString: "箭头与上次成功采样比较；悬停查看间隔与累计变化。应用足迹之和不代表保证释放的内存。")
        trendNote.font = .systemFont(ofSize: 10)
        trendNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(trendNote)

        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = 5
        appsEmptyLabel.font = .systemFont(ofSize: 11)
        appsEmptyLabel.textColor = .secondaryLabelColor
        appsStack.addArrangedSubview(appsEmptyLabel)
        stack.addArrangedSubview(appsStack)
        return card
    }

    func update(memory: MemoryCompositionSnapshot?, apps: [RunningApp]) {
        if let memory, memory.totalBytes > 0 {
            currentTotalBytes = memory.totalBytes
            headlineUsedLabel.stringValue = "已用 \(fmtGB(memory.usedBytes))"
            headlineAvailLabel.stringValue = "总量 \(fmtTotalGB(memory.totalBytes)) · 可用约 \(fmtGB(memory.availableBytes))"
            headlineAvailLabel.toolTip = "可用为物理总量减已用的估算，已含缓存；系统报告空闲页 \(fmtBytes(memory.freeBytes))。"

            switch memory.pressureLevel {
            case 4:
                pressureBadge.stringValue = " 内存紧张 "
                pressureBadge.textColor = .systemRed
            case 2:
                pressureBadge.stringValue = " 压力偏高 "
                pressureBadge.textColor = .systemOrange
            case 1:
                pressureBadge.stringValue = " 压力正常 "
                pressureBadge.textColor = .systemGreen
            default:
                pressureBadge.stringValue = " 压力未知 "
                pressureBadge.textColor = .secondaryLabelColor
            }

            let colors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal]
            compositionBar.segments = zip(memory.physicalCompositionFractions, colors).map { fraction, color in
                .init(fraction: fraction, color: color)
            }

            appMetricValue.stringValue = "\(fmtBytes(memory.appBytes)) (\(pct(memory.appBytes, of: memory.totalBytes)))"
            wiredMetricValue.stringValue = "\(fmtBytes(memory.wiredBytes)) (\(pct(memory.wiredBytes, of: memory.totalBytes)))"
            compressedMetricValue.stringValue = "\(fmtBytes(memory.compressedBytes)) (\(pct(memory.compressedBytes, of: memory.totalBytes)))"
            if memory.compressionSavedBytes > 64 * 1024 * 1024 {
                compressedSubLabel.stringValue = "原始 \(fmtBytes(memory.uncompressedInCompressorBytes)) · 压缩节省约 \(fmtBytes(memory.compressionSavedBytes))"
            } else {
                compressedSubLabel.stringValue = "压缩数据实际占用的物理空间，不是原始页大小"
            }
            cachedMetricValue.stringValue = "\(fmtBytes(memory.cachedBytes)) (\(pct(memory.cachedBytes, of: memory.totalBytes)))"

            if memory.swapTotalBytes > 0 || memory.swapUsedBytes > 0 {
                swapSummaryValue.stringValue = "\(fmtBytes(memory.swapUsedBytes)) / \(fmtBytes(memory.swapTotalBytes))"
            } else {
                swapSummaryValue.stringValue = "0 MB（未使用交换区）"
            }

            if memory.isSwapActive {
                let rate = memory.swapPagesPerSecond
                let rateText = rate < 0.1 ? "< 0.1" : String(format: "%.1f", rate)
                swapActivityValue.stringValue = "交换读写 \(rateText) 页/秒"
                swapActivityValue.textColor = rate >= 8 ? .systemOrange : .secondaryLabelColor
            } else {
                swapActivityValue.stringValue = "本次采样未观察到交换"
                swapActivityValue.textColor = .secondaryLabelColor
            }
            swapActivityValue.toolTip = "只反映采样区间的 Swap 读写，不代表其他磁盘 I/O；首次采样尚无速率基准。"

            vmPagesValue.stringValue = "\(compactCount(memory.pageInsTotal)) 页 / \(compactCount(memory.pageOutsTotal)) 页"
        } else {
            pressureBadge.stringValue = " 采样失败 "
            pressureBadge.textColor = .secondaryLabelColor
            headlineAvailLabel.stringValue = "内存读取失败，数值保留上次结果"
        }

        currentApps = Array(RunningAppHelpers.sortedByResidentMemory(apps).prefix(12))
        let validIDs = Set(currentApps.map(\.identity))
        selectedIdentities = selectedIdentities.intersection(validIDs)
        rebuildAppRows()
        updateCleanButtonTitle()
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
    }

    func setCleaning(_ cleaning: Bool) {
        if cleaning && !isCleaning {
            resultBanner.isHidden = true
        }
        isCleaning = cleaning
        cleanSpinner.isHidden = !cleaning
        if cleaning { cleanSpinner.startAnimation(nil) } else { cleanSpinner.stopAnimation(nil) }
        cleanActionButton.isEnabled = !cleaning
        rebuildAppRows()
        updateCleanButtonTitle()
    }

    func showComparisonResult(
        beforeAvailable: UInt64?,
        afterAvailable: UInt64?,
        closedCount: Int,
        requestedCount: Int? = nil
    ) {
        let comparison = MemoryCleanupComparison(
            beforeAvailable: beforeAvailable,
            afterAvailable: afterAvailable,
            confirmedTerminationCount: closedCount,
            requestedTerminationCount: requestedCount
        )
        resultBanner.isHidden = false
        resultBanner.stringValue = comparison.message
        switch comparison.change {
        case .increased:
            resultBanner.textColor = .systemGreen
        case .decreased:
            resultBanner.textColor = .systemOrange
        case .unchanged, .unavailable:
            resultBanner.textColor = .secondaryLabelColor
        }
        selectedIdentities.removeAll()
        rebuildAppRows()
        updateCleanButtonTitle()
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
    }

    private func rebuildAppRows() {
        appsStack.arrangedSubviews.forEach {
            appsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !currentApps.isEmpty else {
            appsEmptyLabel.stringValue = "未检测到其他常驻应用"
            appsStack.addArrangedSubview(appsEmptyLabel)
            return
        }
        for (idx, app) in currentApps.enumerated() {
            let row = makeAppRow(app: app, index: idx)
            appsStack.addArrangedSubview(row)
        }
    }

    private func makeAppRow(app: RunningApp, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(appCheckToggled(_:)))
        checkbox.tag = index
        checkbox.controlSize = .small
        checkbox.state = selectedIdentities.contains(app.identity) ? .on : .off
        checkbox.isEnabled = !isCleaning
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        if let path = app.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
           path.hasSuffix(".app") {
            iconView.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            iconView.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: app.localizedName)
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        var subParts = [app.isActive ? "前台使用中" : "后台"]
        if let cpu = app.cpuUsage, cpu >= 0.03 {
            subParts.append(String(format: "CPU %.0f%%", cpu * 100))
        }
        if let delta = app.recentMemoryDeltaBytes {
            if delta != 0 {
                subParts.append("\(delta > 0 ? "↑" : "↓") \(fmtBytes(delta.magnitude))")
            } else {
                subParts.append("占用持平")
            }
        } else {
            subParts.append("趋势待采样")
        }
        if app.memoryMeasurement == .resident { subParts.append("驻留量") }
        let subLabel = NSTextField(labelWithString: subParts.joined(separator: " · "))
        subLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        subLabel.textColor = (app.recentMemoryDeltaBytes ?? 0) >= 80 * 1024 * 1024 ? .systemOrange : .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        let interval = app.memorySampleInterval.map { String(format: "距上次成功采样 %.1f 秒；", $0) } ?? "正在建立比较基准；"
        let cumulativeSign = app.memoryDeltaBytes < 0 ? "−" : "+"
        subLabel.toolTip = "\(subParts.joined(separator: " · "))\n\(interval)自本轮基准 \(cumulativeSign)\(fmtBytes(app.memoryDeltaBytes.magnitude))。"

        let memLabel = NSTextField(labelWithString: fmtBytes(app.residentMemoryBytes))
        memLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        memLabel.alignment = .right
        memLabel.translatesAutoresizingMaskIntoConstraints = false
        memLabel.toolTip = app.memoryMeasurement == .physicalFootprint
            ? "该应用主进程的物理内存足迹，不含独立辅助进程，也不是保证释放量。"
            : "物理足迹读取失败，暂用驻留内存量；统计口径改变时会重建趋势基准。"

        let pctLabel = NSTextField(labelWithString: pct(app.residentMemoryBytes, of: currentTotalBytes))
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        pctLabel.textColor = .secondaryLabelColor
        pctLabel.alignment = .right
        pctLabel.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = NSButton(title: "退出", target: self, action: #selector(quitSingleApp(_:)))
        quitBtn.tag = index
        quitBtn.controlSize = .mini
        quitBtn.bezelStyle = .rounded
        quitBtn.toolTip = "请求 \(app.localizedName) 正常退出；有未保存文档时可能需要确认。"
        quitBtn.isEnabled = !isCleaning
        quitBtn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(checkbox)
        row.addSubview(iconView)
        row.addSubview(nameLabel)
        row.addSubview(subLabel)
        row.addSubview(memLabel)
        row.addSubview(pctLabel)
        row.addSubview(quitBtn)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: memLabel.leadingAnchor, constant: -6),

            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: pctLabel.leadingAnchor, constant: -6),

            quitBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            quitBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quitBtn.widthAnchor.constraint(equalToConstant: 38),

            memLabel.trailingAnchor.constraint(equalTo: quitBtn.leadingAnchor, constant: -6),
            memLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),

            pctLabel.trailingAnchor.constraint(equalTo: memLabel.trailingAnchor),
            pctLabel.topAnchor.constraint(equalTo: memLabel.bottomAnchor, constant: 1)
        ])
        return row
    }

    private func updateCleanButtonTitle() {
        let selectedApps = currentApps.filter { selectedIdentities.contains($0.identity) }
        if selectedApps.isEmpty {
            cleanActionButton.title = "整理自身缓存"
            cleanActionButton.toolTip = "只整理本仪表盘自身的缓存和空闲分配页，不会清空其他应用或系统缓存。"
        } else {
            let sum = selectedApps.reduce(UInt64(0)) { total, app in
                total + min(app.residentMemoryBytes, UInt64.max - total)
            }
            cleanActionButton.title = "请求退出（\(selectedApps.count) 个）"
            cleanActionButton.toolTip = "所选主进程合计占用 \(fmtBytes(sum))；实际可用内存变化以整理后采样为准。"
        }
        let idleCandidates = currentApps.filter { !$0.isActive && $0.residentMemoryBytes >= 350 * 1024 * 1024 }
        let allIdleSelected = !idleCandidates.isEmpty && idleCandidates.allSatisfy { selectedIdentities.contains($0.identity) }
        selectIdleButton.title = idleCandidates.isEmpty ? "无后台大户" : (allIdleSelected ? "取消大户勾选" : "勾选后台大户")
        selectIdleButton.isEnabled = !isCleaning && !idleCandidates.isEmpty
    }

    @objc private func appCheckToggled(_ sender: NSButton) {
        guard !isCleaning, currentApps.indices.contains(sender.tag) else { return }
        let id = currentApps[sender.tag].identity
        if sender.state == .on {
            selectedIdentities.insert(id)
        } else {
            selectedIdentities.remove(id)
        }
        updateCleanButtonTitle()
    }

    @objc private func toggleSelectIdleApps() {
        guard !isCleaning else { return }
        let idleCandidates = currentApps.filter { !$0.isActive && $0.residentMemoryBytes >= 350 * 1024 * 1024 }
        let ids = Set(idleCandidates.map(\.identity))
        if ids.isSubset(of: selectedIdentities) {
            selectedIdentities.subtract(ids)
        } else {
            selectedIdentities.formUnion(ids)
        }
        rebuildAppRows()
        updateCleanButtonTitle()
    }

    @objc private func refreshTapped() {
        onRefreshRequested?()
    }

    @objc private func runSmartClean() {
        guard !isCleaning else { return }
        onSmartClean?(currentApps.filter { selectedIdentities.contains($0.identity) }.map(\.identity))
    }

    @objc private func quitSingleApp(_ sender: NSButton) {
        guard !isCleaning, currentApps.indices.contains(sender.tag) else { return }
        onTerminateSingleApp?(currentApps[sender.tag])
    }

    private func cardBodyStack(in card: NSView) -> NSStackView {
        let stack = FullWidthStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return stack
    }

    private func legendDot(color: NSColor, text: String) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8)
        ])
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 10)
        lbl.textColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, lbl])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        return row
    }

    private func breakdownRow(color: NSColor, title: String, subtitle: String, valueField: NSTextField) -> NSView {
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        return breakdownRow(color: color, title: title, subtitleField: sub, valueField: valueField)
    }

    private func breakdownRow(color: NSColor, title: String, subtitleField: NSTextField, valueField: NSTextField) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9)
        ])

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = .systemFont(ofSize: 11.5, weight: .medium)

        subtitleField.font = .systemFont(ofSize: 10)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byWordWrapping
        subtitleField.maximumNumberOfLines = 0

        valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valueField.alignment = .right
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [dot, titleLbl, NSView(), valueField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let row = FullWidthStackView(views: [header, subtitleField])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func kvRow(key: String, valueField: NSTextField) -> NSView {
        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor
        valueField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [k, NSView(), valueField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func thinDivider() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.3)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return box
    }

    private func fmtBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    private func fmtGB(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    private func fmtTotalGB(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }

    private func pct(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int(((Double(part) / Double(total)) * 100).rounded()))%"
    }

    private func compactCount(_ value: UInt64) -> String {
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return "\(value)"
    }
}

enum SafeMemoryOptimizer {
    static func releaseUserSpaceCaches() {
        URLCache.shared.removeAllCachedResponses()
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
