import CoreAudio
import AppKit
import Darwin
import Foundation
import Network
import SystemConfiguration

struct NetworkDiagnosticsSnapshot: Sendable, Equatable {
    let interfaceName: String
    let localIPv4: String
    let routerIPv4: String
    let dnsServers: [String]
    let vpnTunnelActive: Bool

    static func current() -> Self {
        guard let store = SCDynamicStoreCreate(nil, "CPAQuotaBar.NetDiag" as CFString, nil, nil) else {
            return Self(interfaceName: "--", localIPv4: "--", routerIPv4: "--", dnsServers: [], vpnTunnelActive: false)
        }
        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primaryIF = (globalIPv4?["PrimaryInterface"] as? String) ?? "--"
        let router = (globalIPv4?["Router"] as? String) ?? "--"

        var localIP = "--"
        if primaryIF != "--",
           let ifIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(primaryIF)/IPv4" as CFString) as? [String: Any],
           let addresses = ifIPv4["Addresses"] as? [String],
           let first = addresses.first {
            localIP = first
        }

        let globalDNS = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        let dns = (globalDNS?["ServerAddresses"] as? [String]) ?? []
        let vpn = Self.detectActiveTunnel()

        return Self(
            interfaceName: primaryIF,
            localIPv4: localIP,
            routerIPv4: router,
            dnsServers: Array(dns.prefix(3)),
            vpnTunnelActive: vpn
        )
    }

    private static func detectActiveTunnel() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let iface = ptr!.pointee
            guard let namePtr = iface.ifa_name, let addrPtr = iface.ifa_addr else { continue }
            let name = String(cString: namePtr)
            guard name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") else { continue }
            let flags = Int32(iface.ifa_flags)
            if (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && [UInt8(AF_INET), UInt8(AF_INET6)].contains(addrPtr.pointee.sa_family) {
                return true
            }
        }
        return false
    }
}

final class LatencyProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<Int?, Never>?
    private var connection: NWConnection?
    private var timeoutWork: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<Int?, Never>, connection: NWConnection?, timeoutWork: DispatchWorkItem?) -> Bool {
        lock.lock()
        guard !done else {
            lock.unlock()
            connection?.cancel()
            timeoutWork?.cancel()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        self.connection = connection
        self.timeoutWork = timeoutWork
        lock.unlock()
        return true
    }

    func finish(_ value: Int?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let completion = continuation
        let activeConnection = connection
        let timeout = timeoutWork
        continuation = nil
        connection = nil
        timeoutWork = nil
        lock.unlock()
        timeout?.cancel()
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
        completion?.resume(returning: value)
    }
}

enum QuickLatencyProbe {
    static func tcpLatencyMilliseconds(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> Int? {
        guard !Task.isCancelled, !host.isEmpty, port > 0, timeout.isFinite, timeout > 0,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let gate = LatencyProbeGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            let start = DispatchTime.now().uptimeNanoseconds
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.local.CPAQuotaBar.probe.\(UUID().uuidString)")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedMs = max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
                    gate.finish(elapsedMs)
                case .failed, .cancelled:
                    gate.finish(nil)
                default:
                    break
                }
            }
            let timeoutWork = DispatchWorkItem { gate.finish(nil) }
            guard gate.install(continuation, connection: connection, timeoutWork: timeoutWork) else {
                connection.stateUpdateHandler = nil
                return
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + min(timeout, 30), execute: timeoutWork)
            }
        } onCancel: {
            gate.finish(nil)
        }
    }
}

struct ToolboxOperationError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct NetworkProbeDiagnosis: Equatable, Sendable {
    enum Severity: Equatable, Sendable { case success, warning }
    let message: String
    let severity: Severity

    static func evaluate(gateway: Int?, domestic: Int?, international: Int?, hasGateway: Bool) -> Self {
        if domestic == nil && international == nil {
            return Self(message: "两个外部 TCP 探测端点均未响应；可能是端口受限、代理策略或网络故障，不能据此判定完全断网。", severity: .warning)
        }
        if let gateway, gateway >= 45 {
            return Self(message: "网关 TCP 握手约 \(gateway)ms，可进一步检查本地网络；此数值不是带宽测速。", severity: .warning)
        }
        if domestic == nil || international == nil {
            return Self(message: "仅部分外部探测端点响应；未响应可能来自端口限制或网络策略，请结合实际网站访问判断。", severity: .warning)
        }
        if let domestic, let international, domestic >= 100 || international >= 260 {
            return Self(message: "外部端点可连接，但部分 TCP 握手耗时较高；结果不代表下载速度或代理可用性。", severity: .warning)
        }
        if !hasGateway || gateway == nil {
            return Self(message: "两个外部端点可连接；网关未检测或未开放 80 端口，本地链路状态仍未确认。", severity: .warning)
        }
        return Self(message: "三个 TCP 探测端点均有响应；该结果仅反映本次连接，不代表全部服务或带宽状况。", severity: .success)
    }
}

enum DesktopProductivityHelper {
    @MainActor private static let finderPreferenceWriter = FinderPreferenceWriter(operations: .live)

    @MainActor
    struct FinderProcess {
        let isTerminated: @MainActor () -> Bool
        let terminate: @MainActor () -> Bool
    }

    @MainActor
    struct FinderOperations {
        let readPreference: @MainActor (String) -> CFPropertyList?
        let writePreference: @MainActor (String, CFPropertyList?) -> Bool
        let runningFinders: @MainActor () -> [FinderProcess]
        let waitForTermination: @MainActor ([FinderProcess]) async throws -> Bool
        let openFinder: @MainActor () async -> Result<Void, ToolboxOperationError>

        fileprivate static var live: Self {
            Self(
                readPreference: { DesktopProductivityHelper.finderPreference($0) },
                writePreference: { key, value in
                    CFPreferencesSetValue(key as CFString, value, "com.apple.finder" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    return CFPreferencesSynchronize("com.apple.finder" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                },
                runningFinders: {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                        .filter { !$0.isTerminated }
                        .map { application in
                            FinderProcess(isTerminated: { application.isTerminated }, terminate: { application.terminate() })
                        }
                },
                waitForTermination: { finders in
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while finders.contains(where: { !$0.isTerminated() }), ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    return finders.allSatisfy { $0.isTerminated() }
                },
                openFinder: {
                    await withCheckedContinuation { continuation in
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: .init()) { _, error in
                            if let error {
                                continuation.resume(returning: .failure(ToolboxOperationError(message: "无法重新打开访达：\(error.localizedDescription)")))
                            } else {
                                continuation.resume(returning: .success(()))
                            }
                        }
                    }
                }
            )
        }
    }

    @MainActor
    final class FinderPreferenceWriter {
        private let operations: FinderOperations
        private var isChanging = false
        private var pendingTerminations: [FinderProcess] = []
        private(set) var needsFinderRestart = false

        init(operations: FinderOperations) {
            self.operations = operations
        }

        func set(_ key: String, visible: Bool) async -> Result<Void, ToolboxOperationError> {
            guard !isChanging else { return .failure(ToolboxOperationError(message: "访达设置正在更新，请稍后重试")) }
            guard !Task.isCancelled else { return .failure(ToolboxOperationError(message: "操作已取消")) }
            isChanging = true
            defer { isChanging = false }
            let previous = operations.readPreference(key)
            func failure(_ message: String) -> Result<Void, ToolboxOperationError> {
                let restored = operations.writePreference(key, previous)
                    && preferencesMatch(operations.readPreference(key), previous)
                let recovery = needsFinderRestart ? "；访达重启尚未确认，请重试" : ""
                return .failure(ToolboxOperationError(message: message + (restored ? "；原设置已还原" : "；原设置还原失败，请在访达中检查") + recovery))
            }
            let desired: CFPropertyList = visible ? kCFBooleanTrue : kCFBooleanFalse
            guard operations.writePreference(key, desired) else { return failure("无法保存访达设置") }
            if case .failure(let error) = await waitForPendingTerminations() { return failure(error.localizedDescription) }
            let finders = operations.runningFinders().filter { !$0.isTerminated() }
            for finder in finders {
                guard finder.terminate() else { return failure("访达拒绝重新启动，可能有文件操作尚未完成") }
                needsFinderRestart = true
                pendingTerminations.append(finder)
            }
            if case .failure(let error) = await waitForPendingTerminations() { return failure(error.localizedDescription) }
            guard !Task.isCancelled else { return failure("操作已取消") }
            if needsFinderRestart {
                if case .failure(let error) = await operations.openFinder() { return failure(error.localizedDescription) }
                guard operations.runningFinders().contains(where: { !$0.isTerminated() }) else {
                    return failure("尚未确认访达已重新运行")
                }
            }
            guard preferencesMatch(operations.readPreference(key), desired) else { return failure("访达设置写入后未能验证") }
            needsFinderRestart = false
            return .success(())
        }

        private func waitForPendingTerminations() async -> Result<Void, ToolboxOperationError> {
            guard !pendingTerminations.isEmpty else { return .success(()) }
            do {
                guard try await operations.waitForTermination(pendingTerminations),
                      pendingTerminations.allSatisfy({ $0.isTerminated() }) else {
                    return .failure(ToolboxOperationError(message: "访达未能结束，已保留运行中的访达"))
                }
            } catch {
                return .failure(ToolboxOperationError(message: "操作已取消"))
            }
            pendingTerminations.removeAll()
            return .success(())
        }

        private func preferencesMatch(_ observed: CFPropertyList?, _ expected: CFPropertyList?) -> Bool {
            switch (observed, expected) {
            case (nil, nil): return true
            case (let observed?, let expected?): return CFEqual(observed, expected)
            default: return false
            }
        }
    }

    static func areDesktopIconsVisible() -> Bool {
        guard let raw = finderPreference("CreateDesktop") else {
            return true
        }
        if let flag = raw as? Bool { return flag }
        if let str = raw as? String { return !["false", "0", "no"].contains(str.lowercased()) }
        return true
    }

    @MainActor
    static func setDesktopIconsVisible(_ visible: Bool) async -> Result<Void, ToolboxOperationError> {
        await setFinderPreference("CreateDesktop", visible: visible)
    }

    private static func finderPreference(_ key: String) -> CFPropertyList? {
        CFPreferencesSynchronize("com.apple.finder" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, "com.apple.finder" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @MainActor
    private static func setFinderPreference(_ key: String, visible: Bool) async -> Result<Void, ToolboxOperationError> {
        await finderPreferenceWriter.set(key, visible: visible)
    }

    @MainActor
    static func clipboardSummary() -> (description: String, hasRichFormatting: Bool, plainText: String?) {
        let pb = NSPasteboard.general
        let plain = pb.string(forType: .string)
        guard let plain, !plain.isEmpty else {
            return ("剪贴板暂无文本", false, nil)
        }
        let types = Set(pb.types ?? [])
        let richTypes: Set<NSPasteboard.PasteboardType> = [.html, .rtf, .rtfd]
        let isRich = !types.isDisjoint(with: richTypes)
        return ("\(isRich ? "含富文本样式" : "纯文本") · \(plain.count) 字符", isRich, plain)
    }

    @MainActor
    @discardableResult
    static func sanitizeClipboardToPlainText() -> Int? {
        let pb = NSPasteboard.general
        guard let plain = pb.string(forType: .string), !plain.isEmpty else { return nil }
        pb.clearContents()
        return pb.setString(plain, forType: .string) ? plain.count : nil
    }
}

@MainActor
final class QuickToolboxDashboardView: NSView {
    var onSelectKeepAwakeMode: ((Int?) -> Void)? // nil = off, 0 = indefinite, >0 = minutes
    var onEnterScreenClean: (() -> Void)?
    var onTogglePresentationMode: (() -> Bool)?
    var keepAwakeSummaryProvider: (() -> (modeIndex: Int, statusText: String))?
    var onHeightChanged: (() -> Void)?

    private let rootStack = FullWidthStackView()
    private let presentationToggleButton = NSButton(title: "演示净空", target: nil, action: nil)
    private let desktopToggleButton = NSButton(title: "隐藏桌面图标", target: nil, action: nil)
    private let screenCleanButton = NSButton(title: "擦屏模式", target: nil, action: nil)
    private let cleanClipboardButton = NSButton(title: "纯文本剪贴板", target: nil, action: nil)

    private let keepAwakeSegment = NSSegmentedControl(
        labels: ["关闭", "30分", "1小时", "2小时", "一直"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sceneStatusLabel = NSTextField(wrappingLabelWithString: "跟随系统默认休眠设置")

    private let audioOutputPopup = NSPopUpButton()
    private let audioInputPopup = NSPopUpButton()
    private let lockBuiltinMicSwitch = NSSwitch()
    private let audioStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var audioObserverToken: UUID?
    private var presentationObserverToken: UUID?

    private let netInterfaceValue = NSTextField(labelWithString: "--")
    private let netIPValue = NSTextField(labelWithString: "--")
    private let netRouterValue = NSTextField(labelWithString: "--")
    private let netDNSValue = NSTextField(labelWithString: "--")
    private let latencyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let latencyDiagnosisLabel = NSTextField(wrappingLabelWithString: "")
    private let pingButton = NSButton(title: "延迟自检", target: nil, action: nil)
    private var rawLocalIP = "--"
    private var rawRouterIP = "--"
    private var networkSnapshot: NetworkDiagnosticsSnapshot?

    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private var probeTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var productivityTask: Task<Void, Never>?
    private var audioOutputs: [AudioEndpointDevice] = []
    private var audioInputs: [AudioEndpointDevice] = []

    var cardCount: Int {
        rootStack.arrangedSubviews.filter { $0 is LiquidGlassCardView }.count
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 376).isActive = true

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        rootStack.addArrangedSubview(makeAudioGuardCard())
        rootStack.addArrangedSubview(makeScreenAndDesktopCard())
        rootStack.addArrangedSubview(makeNetworkCard())

        feedbackLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        feedbackLabel.textColor = .systemGreen
        feedbackLabel.alignment = .center
        feedbackLabel.isHidden = true
        rootStack.addArrangedSubview(feedbackLabel)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        audioObserverToken = CoreAudioDeviceManager.shared.addObserver { [weak self] in
            self?.refreshAudioDevices()
        }
        presentationObserverToken = PresentationModeController.shared.addObserver { [weak self] in
            self?.refreshPresentationState()
            self?.refreshNetworkDetails()
        }
    }

    override var intrinsicContentSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: 376, height: rootStack.fittingSize.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        probeTask?.cancel()
        feedbackTask?.cancel()
        let audioToken = audioObserverToken
        let presentationToken = presentationObserverToken
        Task { @MainActor in
            if let audioToken { CoreAudioDeviceManager.shared.removeObserver(audioToken) }
            if let presentationToken { PresentationModeController.shared.removeObserver(presentationToken) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelProbe()
            feedbackTask?.cancel()
            feedbackLabel.isHidden = true
        }
    }

    private func refreshPresentationState() {
        let controller = PresentationModeController.shared
        let presActive = controller.isActive
        if presActive {
            feedbackTask?.cancel()
            feedbackLabel.isHidden = true
        }
        presentationToggleButton.title = presActive ? "退出演示" : "演示净空"
        presentationToggleButton.isEnabled = !controller.isTransitioning && productivityTask == nil
        desktopToggleButton.isEnabled = !presActive && !controller.isTransitioning && productivityTask == nil

        let keepAwakeSummary = keepAwakeSummaryProvider?() ?? (modeIndex: 0, statusText: "跟随系统默认休眠设置")
        keepAwakeSegment.selectedSegment = keepAwakeSummary.modeIndex
        if let err = controller.lastError {
            sceneStatusLabel.stringValue = err
            sceneStatusLabel.textColor = .systemRed
        } else if controller.isTransitioning {
            sceneStatusLabel.stringValue = "正在切换演示净空状态，请稍候…"
            sceneStatusLabel.textColor = .secondaryLabelColor
        } else if presActive {
            sceneStatusLabel.stringValue = "演示净空中：临时常亮 · 桌面图标隐藏 · IP 已打码（原定时保留）"
            sceneStatusLabel.textColor = .systemOrange
        } else {
            sceneStatusLabel.stringValue = keepAwakeSummary.statusText
            sceneStatusLabel.textColor = .secondaryLabelColor
        }
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    func refreshState() {
        refreshPresentationState()
        refreshAudioDevices()
        refreshNetworkDetails()

        let iconsVisible = DesktopProductivityHelper.areDesktopIconsVisible()
        desktopToggleButton.title = iconsVisible ? "隐藏桌面图标" : "显示桌面图标"
        desktopToggleButton.toolTip = iconsVisible ? "临时隐藏桌面文件与图标（访达仍可正常访问）" : "恢复显示桌面文件与图标"

        let clip = DesktopProductivityHelper.clipboardSummary()
        cleanClipboardButton.toolTip = "一键剥离富文本样式为纯文本（当前：\(clip.description)）"
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
    }

    private func refreshNetworkDetails() {
        let net = NetworkDiagnosticsSnapshot.current()
        if let previous = networkSnapshot, previous != net { cancelProbe() }
        networkSnapshot = net
        rawLocalIP = net.localIPv4
        rawRouterIP = net.routerIPv4
        let mask = PresentationModeController.shared.maskIPAddresses
        netInterfaceValue.stringValue = net.vpnTunnelActive ? "\(net.interfaceName) · VPN" : net.interfaceName
        netInterfaceValue.textColor = net.vpnTunnelActive ? .systemTeal : .labelColor
        netInterfaceValue.toolTip = net.vpnTunnelActive ? "主用接口 \(net.interfaceName)，检测到活动隧道接口" : "主用接口 \(net.interfaceName)"
        netIPValue.stringValue = PresentationModeController.maskedIP(net.localIPv4, masked: mask)
        netRouterValue.stringValue = PresentationModeController.maskedIP(net.routerIPv4, masked: mask)
        let maskedDNS = net.dnsServers.map { PresentationModeController.maskedIP($0, masked: mask) }
        if maskedDNS.isEmpty {
            netDNSValue.stringValue = "--"
            netDNSValue.toolTip = nil
        } else if maskedDNS.count == 1 {
            netDNSValue.stringValue = maskedDNS[0]
            netDNSValue.toolTip = maskedDNS[0]
        } else {
            netDNSValue.stringValue = "\(maskedDNS[0]) +\(maskedDNS.count - 1)"
            netDNSValue.toolTip = maskedDNS.joined(separator: ", ")
        }
    }

    private func makeAudioGuardCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardContentStack(in: card)
        stack.addArrangedSubview(sectionHeader(symbol: "headphones", title: "音频切换与音质守卫"))

        audioOutputPopup.controlSize = .small
        audioOutputPopup.target = self
        audioOutputPopup.action = #selector(audioOutputSelected)
        audioOutputPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioOutputPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 236).isActive = true
        let outLbl = NSTextField(labelWithString: "输出设备")
        outLbl.font = .systemFont(ofSize: 11)
        outLbl.textColor = .secondaryLabelColor
        let outRow = NSStackView(views: [outLbl, NSView(), audioOutputPopup])
        outRow.orientation = .horizontal
        outRow.alignment = .centerY
        stack.addArrangedSubview(outRow)

        audioInputPopup.controlSize = .small
        audioInputPopup.target = self
        audioInputPopup.action = #selector(audioInputSelected)
        audioInputPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioInputPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 236).isActive = true
        let inLbl = NSTextField(labelWithString: "输入麦克风")
        inLbl.font = .systemFont(ofSize: 11)
        inLbl.textColor = .secondaryLabelColor
        let inRow = NSStackView(views: [inLbl, NSView(), audioInputPopup])
        inRow.orientation = .horizontal
        inRow.alignment = .centerY
        stack.addArrangedSubview(inRow)

        lockBuiltinMicSwitch.controlSize = .small
        lockBuiltinMicSwitch.target = self
        lockBuiltinMicSwitch.action = #selector(lockBuiltinMicToggled)
        let guardLbl = NSTextField(wrappingLabelWithString: "锁定内置麦克风（防蓝牙耳机切通话低音质）")
        guardLbl.font = .systemFont(ofSize: 10.5, weight: .medium)
        let guardRow = NSStackView(views: [guardLbl, NSView(), lockBuiltinMicSwitch])
        guardRow.orientation = .horizontal
        guardRow.alignment = .centerY
        stack.addArrangedSubview(guardRow)
        audioStatusLabel.font = .systemFont(ofSize: 10.5)
        audioStatusLabel.textColor = .systemRed
        audioStatusLabel.isHidden = true
        stack.addArrangedSubview(audioStatusLabel)
        return card
    }

    private func refreshAudioDevices() {
        let snap = CoreAudioDeviceManager.shared.snapshot()
        audioOutputs = snap.outputs
        audioInputs = snap.inputs

        audioOutputPopup.removeAllItems()
        for device in snap.outputs { addAudioItem(device, to: audioOutputPopup) }
        audioOutputPopup.select(nil)
        if let defOut = snap.defaultOutput,
           let idx = snap.outputs.firstIndex(where: { $0.id == defOut }) {
            audioOutputPopup.selectItem(at: idx)
        }
        audioOutputPopup.isEnabled = !snap.outputs.isEmpty
        if snap.outputs.isEmpty { audioOutputPopup.addItem(withTitle: "未检测到输出设备") }

        audioInputPopup.removeAllItems()
        for device in snap.inputs { addAudioItem(device, to: audioInputPopup) }
        audioInputPopup.select(nil)
        if let defIn = snap.defaultInput,
           let idx = snap.inputs.firstIndex(where: { $0.id == defIn }) {
            audioInputPopup.selectItem(at: idx)
        }
        audioInputPopup.isEnabled = !snap.inputs.isEmpty
        if snap.inputs.isEmpty { audioInputPopup.addItem(withTitle: "未检测到麦克风") }

        lockBuiltinMicSwitch.state = CoreAudioDeviceManager.shared.isBuiltinMicLocked ? .on : .off
        lockBuiltinMicSwitch.isEnabled = snap.inputs.contains(where: \.isBuiltIn) || CoreAudioDeviceManager.shared.isBuiltinMicLocked
        let error = CoreAudioDeviceManager.shared.lastError ?? CoreAudioDeviceManager.shared.monitoringError
        audioStatusLabel.stringValue = error ?? ""
        audioStatusLabel.isHidden = error == nil
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func addAudioItem(_ device: AudioEndpointDevice, to popup: NSPopUpButton) {
        let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
        item.representedObject = NSNumber(value: device.id)
        popup.menu?.addItem(item)
    }

    private func makeScreenAndDesktopCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardContentStack(in: card)
        stack.addArrangedSubview(sectionHeader(symbol: "sun.max.fill", title: "屏幕常亮与桌面效率"))

        keepAwakeSegment.controlSize = .small
        keepAwakeSegment.segmentDistribution = .fillEqually
        keepAwakeSegment.target = self
        keepAwakeSegment.action = #selector(keepAwakeChanged)
        stack.addArrangedSubview(keepAwakeSegment)

        sceneStatusLabel.font = .systemFont(ofSize: 10.5)
        sceneStatusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sceneStatusLabel)

        configureActionButton(presentationToggleButton, symbol: "sparkles.tv", action: #selector(togglePresentationTapped))
        presentationToggleButton.toolTip = "一键开启临时常亮、隐藏桌面图标并对局域网 IP 打码；退出时恢复原状"
        configureActionButton(desktopToggleButton, symbol: "menubar.dock.rectangle", action: #selector(toggleDesktopIcons))
        configureActionButton(screenCleanButton, symbol: "hand.raised.fill", action: #selector(triggerScreenClean))
        screenCleanButton.toolTip = "锁定键盘与鼠标点击，方便清洁屏幕与键盘"
        configureActionButton(cleanClipboardButton, symbol: "doc.on.clipboard", action: #selector(cleanClipboard))

        let primaryRow = NSStackView(views: [presentationToggleButton, desktopToggleButton])
        primaryRow.orientation = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 6
        stack.addArrangedSubview(primaryRow)

        let secondaryRow = NSStackView(views: [screenCleanButton, cleanClipboardButton])
        secondaryRow.orientation = .horizontal
        secondaryRow.distribution = .fillEqually
        secondaryRow.spacing = 6
        stack.addArrangedSubview(secondaryRow)
        return card
    }

    private func makeNetworkCard() -> NSView {
        let card = LiquidGlassCardView()
        let stack = cardContentStack(in: card)

        let copyIPBtn = NSButton(title: "复制 IP", target: self, action: #selector(copyLocalIP))
        copyIPBtn.controlSize = .mini
        copyIPBtn.bezelStyle = .rounded
        pingButton.target = self
        pingButton.action = #selector(runLatencyProbe)
        pingButton.controlSize = .mini
        pingButton.bezelStyle = .rounded
        pingButton.toolTip = "并发检测网关、国内与国际节点 TCP 握手耗时（非带宽测速）"
        let netSettingsBtn = NSButton(title: "网络设置", target: self, action: #selector(openNetworkSettings))
        netSettingsBtn.controlSize = .mini
        netSettingsBtn.bezelStyle = .rounded

        let headerRow = NSStackView(views: [
            sectionHeader(symbol: "network", title: "网络速览"),
            NSView(),
            copyIPBtn,
            pingButton,
            netSettingsBtn
        ])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 5
        stack.addArrangedSubview(headerRow)

        let gridTop = NSStackView(views: [
            compactNetworkCell(title: "接口", valueLabel: netInterfaceValue),
            compactNetworkCell(title: "本机 IP", valueLabel: netIPValue)
        ])
        gridTop.orientation = .horizontal
        gridTop.distribution = .fillEqually
        gridTop.spacing = 6
        stack.addArrangedSubview(gridTop)

        let gridBottom = NSStackView(views: [
            compactNetworkCell(title: "网关", valueLabel: netRouterValue),
            compactNetworkCell(title: "DNS", valueLabel: netDNSValue)
        ])
        gridBottom.orientation = .horizontal
        gridBottom.distribution = .fillEqually
        gridBottom.spacing = 6
        stack.addArrangedSubview(gridBottom)

        latencyStatusLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        latencyStatusLabel.textColor = .secondaryLabelColor
        latencyStatusLabel.isHidden = true
        stack.addArrangedSubview(latencyStatusLabel)

        latencyDiagnosisLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        latencyDiagnosisLabel.textColor = .systemTeal
        latencyDiagnosisLabel.isHidden = true
        stack.addArrangedSubview(latencyDiagnosisLabel)
        return card
    }

    private func cardContentStack(in card: NSView) -> NSStackView {
        let stack = FullWidthStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
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

    private func sectionHeader(symbol: String, title: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemBlue
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func compactNetworkCell(title: String, valueLabel: NSTextField) -> NSView {
        let tile = NetworkInfoTileView()
        let left = NSTextField(labelWithString: title)
        left.font = .systemFont(ofSize: 10.5)
        left.textColor = .secondaryLabelColor
        left.setContentHuggingPriority(.required, for: .horizontal)
        left.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [left, spacer, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(row)
        NSLayoutConstraint.activate([
            tile.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    private func configureActionButton(_ button: NSButton, symbol: String, action: Selector) {
        button.target = self
        button.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.bezelStyle = .rounded
    }

    private func flashFeedback(_ text: String, isError: Bool = false) {
        feedbackTask?.cancel()
        feedbackLabel.stringValue = text
        feedbackLabel.textColor = isError ? .systemRed : .systemGreen
        feedbackLabel.isHidden = false
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(isError ? 6 : 3)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.feedbackLabel.isHidden = true
            self.feedbackTask = nil
            self.invalidateIntrinsicContentSize()
            self.onHeightChanged?()
        }
    }

    @objc private func keepAwakeChanged() {
        let map: [Int?] = [nil, 30, 60, 120, 0]
        let idx = min(max(0, keepAwakeSegment.selectedSegment), map.count - 1)
        onSelectKeepAwakeMode?(map[idx])
        refreshState()
    }

    @objc private func triggerScreenClean() { onEnterScreenClean?() }

    @objc private func togglePresentationTapped() {
        guard let onTogglePresentationMode else { flashFeedback("演示模式暂不可用", isError: true); return }
        _ = onTogglePresentationMode()
        refreshPresentationState()
        refreshNetworkDetails()
    }

    @objc private func audioOutputSelected() {
        guard let selectedID = (audioOutputPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value,
              let dev = audioOutputs.first(where: { $0.id == selectedID }) else { return }
        if CoreAudioDeviceManager.shared.setDefaultOutput(dev.id) {
            flashFeedback("已切换音频输出至：\(dev.name)")
        } else {
            flashFeedback(CoreAudioDeviceManager.shared.lastError ?? "切换音频输出失败", isError: true)
        }
        refreshAudioDevices()
    }

    @objc private func audioInputSelected() {
        guard let selectedID = (audioInputPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value,
              let dev = audioInputs.first(where: { $0.id == selectedID }) else { return }
        if CoreAudioDeviceManager.shared.setDefaultInput(dev.id) {
            flashFeedback("已切换麦克风至：\(dev.name)")
        } else {
            flashFeedback(CoreAudioDeviceManager.shared.lastError ?? "切换麦克风失败", isError: true)
        }
        refreshAudioDevices()
    }

    @objc private func lockBuiltinMicToggled() {
        let on = lockBuiltinMicSwitch.state == .on
        let success = CoreAudioDeviceManager.shared.setBuiltinMicrophoneLocked(on)
        refreshAudioDevices()
        if success {
            flashFeedback(on ? "已开启守卫：保持内置麦克风为默认输入" : "已关闭内置麦克风守卫")
        } else {
            flashFeedback(CoreAudioDeviceManager.shared.lastError ?? "麦克风守卫开启失败", isError: true)
        }
    }

    @objc private func copyLocalIP() {
        let ip = rawLocalIP
        guard ip != "--", !ip.isEmpty else { flashFeedback("当前没有可复制的 IPv4 地址", isError: true); return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(ip, forType: .string) {
            flashFeedback(PresentationModeController.shared.maskIPAddresses ? "已复制局域网 IP（屏幕继续隐藏地址）" : "已复制局域网 IP：\(ip)")
        } else {
            flashFeedback("写入剪贴板失败，请重试", isError: true)
        }
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        pingButton.isEnabled = true
        latencyStatusLabel.stringValue = ""
        latencyStatusLabel.isHidden = true
        latencyDiagnosisLabel.isHidden = true
    }

    @objc private func runLatencyProbe() {
        cancelProbe()
        refreshNetworkDetails()
        pingButton.isEnabled = false
        latencyStatusLabel.stringValue = "正在并发探测网关、国内 DNS 与国际节点…"
        latencyStatusLabel.isHidden = false
        latencyDiagnosisLabel.isHidden = true
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        let router = rawRouterIP
        probeTask = Task { [weak self] in
            async let gwLatency: Int? = (router != "--" && !router.isEmpty)
                ? QuickLatencyProbe.tcpLatencyMilliseconds(host: router, port: 80, timeout: 1.2)
                : nil
            async let cnLatency = QuickLatencyProbe.tcpLatencyMilliseconds(host: "223.5.5.5", port: 53, timeout: 1.8)
            async let intlLatency = QuickLatencyProbe.tcpLatencyMilliseconds(host: "1.1.1.1", port: 443, timeout: 2.0)
            let (gw, cn, intl) = await (gwLatency, cnLatency, intlLatency)
            guard !Task.isCancelled, let self else { return }
            guard NetworkDiagnosticsSnapshot.current() == self.networkSnapshot else {
                self.refreshNetworkDetails()
                return
            }
            self.probeTask = nil
            self.pingButton.isEnabled = true
            func fmt(_ ms: Int?) -> String { ms.map { "\($0)ms" } ?? "未响应" }
            var parts: [String] = []
            if router != "--" { parts.append("网关 \(gw.map { "\($0)ms" } ?? "禁端口/超时")") }
            parts.append("国内 \(fmt(cn))")
            parts.append("国际 \(fmt(intl))")
            self.latencyStatusLabel.stringValue = parts.joined(separator: " · ")

            let diagnosis = NetworkProbeDiagnosis.evaluate(gateway: gw, domestic: cn, international: intl, hasGateway: router != "--" && !router.isEmpty)
            self.latencyDiagnosisLabel.textColor = diagnosis.severity == .success ? .systemGreen : .systemOrange
            self.latencyDiagnosisLabel.stringValue = diagnosis.message
            self.latencyDiagnosisLabel.isHidden = false
            self.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        }
    }

    @objc private func toggleDesktopIcons() {
        guard !PresentationModeController.shared.isActive else { return }
        let next = !DesktopProductivityHelper.areDesktopIconsVisible()
        guard productivityTask == nil, !PresentationModeController.shared.isTransitioning else { return }
        productivityTask = Task { [weak self] in
            let result = await DesktopProductivityHelper.setDesktopIconsVisible(next)
            guard let self else { return }
            self.productivityTask = nil
            self.refreshState()
            switch result {
            case .success:
                self.flashFeedback(next ? "已恢复桌面图标显示" : "已隐藏桌面图标")
            case .failure(let error):
                self.flashFeedback(error.localizedDescription, isError: true)
            }
        }
        refreshPresentationState()
    }

    @objc private func cleanClipboard() {
        if let count = DesktopProductivityHelper.sanitizeClipboardToPlainText() {
            refreshState()
            flashFeedback("已净化剪贴板为纯文本（\(count) 字符）")
        } else {
            flashFeedback("剪贴板中没有文本，或写入纯文本失败", isError: true)
        }
    }

    @objc private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class NetworkInfoTileView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.032).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        }
    }
}
