import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import IOKit

struct AudioEndpointDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

@MainActor
final class CoreAudioDeviceManager {
    static let shared = CoreAudioDeviceManager()
    static let lockBuiltinMicDefaultsKey = "superDashboardLockBuiltinMic"

    var onDevicesChanged: (() -> Void)?
    private var observers: [UUID: () -> Void] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var lastError: String?
    private(set) var monitoringError: String?
    private var volumeListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observedOutput: AudioDeviceID?

    var isBuiltinMicLocked: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lockBuiltinMicDefaultsKey) }
        set { setBuiltinMicrophoneLocked(newValue) }
    }

    private init() {
        registerDeviceListeners()
    }

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func notifyObservers() {
        onDevicesChanged?()
        Array(observers.values).forEach { $0() }
    }

    func snapshot() -> (
        outputs: [AudioEndpointDevice],
        inputs: [AudioEndpointDevice],
        defaultOutput: AudioDeviceID?,
        defaultInput: AudioDeviceID?,
        outputVolumePercent: Double?,
        canSetOutputVolume: Bool
    ) {
        let allIDs = allDeviceIDs()
        var outputs: [AudioEndpointDevice] = []
        var inputs: [AudioEndpointDevice] = []

        for id in allIDs {
            guard let name = deviceName(id), !name.isEmpty else { continue }
            let transport = transportType(id)
            if channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 {
                outputs.append(AudioEndpointDevice(id: id, name: name, transportType: transport))
            }
            if channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0 {
                inputs.append(AudioEndpointDevice(id: id, name: name, transportType: transport))
            }
        }
        let defOut = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defIn = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
        let vol = defOut.flatMap { readVolumePercent(deviceID: $0) }
        updateVolumeListeners(deviceID: defOut)
        return (outputs, inputs, defOut, defIn, vol, defOut.map { !volumeAddresses(deviceID: $0, writableOnly: true).isEmpty } ?? false)
    }

    @discardableResult
    func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        let success = setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        notifyObservers()
        return success
    }

    @discardableResult
    func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        let success = setDefaultDevice(id, selector: kAudioHardwarePropertyDefaultInputDevice)
        if success, transportType(id) != kAudioDeviceTransportTypeBuiltIn {
            UserDefaults.standard.set(false, forKey: Self.lockBuiltinMicDefaultsKey)
        }
        notifyObservers()
        return success
    }

    @discardableResult
    func setOutputVolumePercent(_ percent: Double) -> Bool {
        lastError = nil
        guard percent.isFinite, let outID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
            lastError = "当前没有可调节的音频输出设备"
            return false
        }
        var scalar = Float32(min(max(percent / 100.0, 0), 1))
        let addresses = volumeAddresses(deviceID: outID, writableOnly: true)
        guard !addresses.isEmpty else {
            lastError = "此设备不支持系统音量调节，请使用设备上的音量控制"
            return false
        }
        let size = UInt32(MemoryLayout<Float32>.size)
        for var address in addresses {
            let status = AudioObjectSetPropertyData(outID, &address, 0, nil, size, &scalar)
            if status != noErr {
                lastError = "音量调节失败（Core Audio \(status)），请重新选择输出设备"
                return false
            }
        }
        return true
    }

    @discardableResult
    func setBuiltinMicrophoneLocked(_ locked: Bool) -> Bool {
        lastError = nil
        if locked {
            guard let builtin = snapshot().inputs.first(where: \.isBuiltIn) else {
                lastError = "未检测到内置麦克风，无法启用守卫"
                notifyObservers()
                return false
            }
            guard defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) == builtin.id
                || setDefaultDevice(builtin.id, selector: kAudioHardwarePropertyDefaultInputDevice) else {
                notifyObservers()
                return false
            }
        }
        UserDefaults.standard.set(locked, forKey: Self.lockBuiltinMicDefaultsKey)
        notifyObservers()
        return true
    }

    @discardableResult
    func enforceBuiltinMicrophoneIfNeeded() -> Bool {
        guard isBuiltinMicLocked else { return true }
        let snap = snapshot()
        guard let builtinMic = snap.inputs.first(where: \.isBuiltIn) else {
            lastError = "守卫暂不可用：未检测到内置麦克风"
            return false
        }
        guard snap.defaultInput != builtinMic.id else { return true }
        return setDefaultDevice(builtinMic.id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func makeListener() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.enforceBuiltinMicrophoneIfNeeded()
            self.notifyObservers()
            self.refreshTask = nil
        }
    }

    private func registerDeviceListeners() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, makeListener())
            if status != noErr { monitoringError = "无法监听音频设备变化（Core Audio \(status)），请重新打开工具箱刷新" }
        }
    }

    private func updateVolumeListeners(deviceID: AudioDeviceID?) {
        guard observedOutput != deviceID else { return }
        for (oldID, oldAddress, block) in volumeListeners {
            var address = oldAddress
            AudioObjectRemovePropertyListenerBlock(oldID, &address, .main, block)
        }
        volumeListeners.removeAll()
        observedOutput = deviceID
        guard let deviceID else { return }
        for var address in volumeAddresses(deviceID: deviceID, writableOnly: false) {
            let block = makeListener()
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                volumeListeners.append((deviceID, address, block))
            }
        }
    }

    private func volumeAddresses(deviceID: AudioDeviceID, writableOnly: Bool) -> [AudioObjectPropertyAddress] {
        func supported(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress? {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { return nil }
            if writableOnly {
                var settable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { return nil }
            }
            return address
        }
        if let virtual = supported(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain) { return [virtual] }
        if let main = supported(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) { return [main] }
        let channels = channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return [] }
        return (1...channels).compactMap { supported(kAudioDevicePropertyVolumeScalar, UInt32($0)) }
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(dataSize) / MemoryLayout<AudioDeviceID>.size)).filter { $0 != kAudioObjectUnknown }
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        lastError = nil
        let scope = selector == kAudioHardwarePropertyDefaultInputDevice ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        guard allDeviceIDs().contains(id), channelCount(id, scope: scope) > 0 else {
            lastError = "设备已断开或不支持所选音频方向，请重新选择"
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &mutableID)
        if status != noErr { lastError = "切换音频设备失败（Core Audio \(status)）" }
        return status == noErr
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let str = cfName?.takeRetainedValue() as String? else { return nil }
        return str
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func readVolumePercent(deviceID: AudioDeviceID) -> Double? {
        var values: [Double] = []
        for var address in volumeAddresses(deviceID: deviceID, writableOnly: false) {
            var scalar: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar) == noErr, scalar.isFinite {
                values.append(Double(min(max(scalar, 0), 1)) * 100)
            }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

@MainActor
protocol PresentationKeepAwakeControlling: AnyObject {
    var isPreventingSleep: Bool { get }
    func beginTemporaryHold()
    func endTemporaryHold()
}

extension KeepAwakeController: PresentationKeepAwakeControlling {}

@MainActor
final class PresentationModeController {
    static let shared = PresentationModeController()
    private(set) var isActive = false
    private(set) var isTransitioning = false
    private(set) var lastError: String?
    private var savedDesktopVisible = true
    private var desktopRecoveryPending = false
    private var heldKeepAwake: (any PresentationKeepAwakeControlling)?
    private var transitionTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]
    private let readDesktopVisibility: () -> Bool
    private let writeDesktopVisibility: (Bool) async -> Result<Void, ToolboxOperationError>

    init(
        readDesktopVisibility: @escaping () -> Bool = { DesktopProductivityHelper.areDesktopIconsVisible() },
        writeDesktopVisibility: @escaping (Bool) async -> Result<Void, ToolboxOperationError> = { await DesktopProductivityHelper.setDesktopIconsVisible($0) }
    ) {
        self.readDesktopVisibility = readDesktopVisibility
        self.writeDesktopVisibility = writeDesktopVisibility
    }

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func notifyObservers() { Array(observers.values).forEach { $0() } }

    var maskIPAddresses: Bool {
        isActive || UserDefaults.standard.bool(forKey: "superDashboardMaskIP")
    }

    var requiresQuitRestoration: Bool {
        isActive || isTransitioning || desktopRecoveryPending
    }

    func toggle(keepAwake: any PresentationKeepAwakeControlling) -> Bool {
        guard !isTransitioning else { return isActive }
        if isActive {
            deactivate(keepAwake: keepAwake)
        } else {
            activate(keepAwake: keepAwake)
        }
        return isActive
    }

    func activate(keepAwake: any PresentationKeepAwakeControlling) {
        guard !requiresQuitRestoration else { return }
        lastError = nil
        savedDesktopVisible = readDesktopVisibility()
        keepAwake.beginTemporaryHold()
        guard keepAwake.isPreventingSleep else {
            keepAwake.endTemporaryHold()
            lastError = "无法申请屏幕常亮，演示模式未开启"
            notifyObservers()
            return
        }
        heldKeepAwake = keepAwake
        isActive = true
        isTransitioning = true
        transitionTask = Task {
            if savedDesktopVisible {
                desktopRecoveryPending = true
                if case .failure(let error) = await writeDesktopVisibility(false) {
                    lastError = error.localizedDescription
                }
            }
            isTransitioning = false
            transitionTask = nil
            notifyObservers()
        }
        notifyObservers()
    }

    func deactivate(keepAwake: any PresentationKeepAwakeControlling) {
        beginRestoring()
    }

    private func beginRestoring() {
        guard isActive || desktopRecoveryPending, !isTransitioning else { return }
        lastError = nil
        isTransitioning = true
        transitionTask = Task {
            let requiresDesktopWrite = desktopRecoveryPending || savedDesktopVisible != readDesktopVisibility()
            if requiresDesktopWrite { desktopRecoveryPending = true }
            if requiresDesktopWrite,
               case .failure(let error) = await writeDesktopVisibility(savedDesktopVisible) {
                lastError = "恢复桌面失败：\(error.localizedDescription)，请重试退出演示模式"
            } else {
                heldKeepAwake?.endTemporaryHold()
                heldKeepAwake = nil
                isActive = false
                desktopRecoveryPending = false
            }
            isTransitioning = false
            transitionTask = nil
            notifyObservers()
        }
        notifyObservers()
    }

    func waitForTransition() async { await transitionTask?.value }

    @discardableResult
    func restoreOnQuit() async -> Bool {
        await waitForTransition()
        beginRestoring()
        await waitForTransition()
        return !requiresQuitRestoration
    }

    static func maskedIP(_ ip: String, masked: Bool) -> String {
        guard masked, ip != "--", !ip.isEmpty else { return ip }
        let parts = ip.split(separator: ".")
        if parts.count == 4 {
            return "\(parts[0]).\(parts[1]).*.*"
        }
        return "已隐藏"
    }
}

struct WirelessPeripheralBattery: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let percent: Int
    var isCharging: Bool = false
}

enum ListeningPortTerminationError: LocalizedError, Equatable, Sendable {
    case identityUnavailable
    case identityChanged
    case protectedProcess
    case runningApplication
    case listenerNotVerified
    case cancelled
    case signalFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .identityUnavailable: "未能记录进程身份，无法安全终止；请刷新端口列表"
        case .identityChanged: "进程已退出或 PID 已被重新使用，未发送终止信号；请刷新列表"
        case .protectedProcess: "已保护仪表盘、父进程、系统进程及其他用户的进程，不能在此终止"
        case .runningApplication: "此端口属于应用程序，请从应用页正常退出，以保护未保存内容"
        case .listenerNotVerified: "未能确认该进程仍在监听原地址和端口，未发送终止信号；请刷新列表"
        case .cancelled: "操作已取消，未发送终止信号"
        case .signalFailed(let code): "系统拒绝终止请求（errno \(code)）"
        }
    }
}

enum ListeningPortProcessController {
    struct Identity: Hashable, Sendable {
        let process: RunningAppIdentity
        let effectiveUserID: uid_t
        let realUserID: uid_t
        let executablePath: String
    }

    struct Target: Identifiable, Sendable {
        let item: ListeningPortItem
        let identity: Identity?
        var id: String { item.id }
    }

    struct Operations: Sendable {
        let currentUserID: uid_t
        let protectedProcessIDs: Set<pid_t>
        let readIdentity: @Sendable (pid_t) -> Identity?
        let readListeners: @Sendable () -> [ListeningPortItem]
        let sendSignal: @Sendable (pid_t, Int32) -> Int32
        let shouldContinue: @Sendable () -> Bool
    }

    static func scan() -> [Target] {
        guard !Task.isCancelled else { return [] }
        let before = processIdentities()
        let items = ListeningPortScanner.scan()
        guard !Task.isCancelled else { return [] }
        return items.map { item in
            let identity = readIdentity(item.pid)
            let verified = identity.flatMap { before[item.pid] == $0.process ? $0 : nil }
            return Target(item: item, identity: verified)
        }
    }

    static func terminateSafely(_ target: Target, using injectedOperations: Operations? = nil) -> Result<Void, ListeningPortTerminationError> {
        let operations = injectedOperations ?? Operations(
            currentUserID: getuid(),
            protectedProcessIDs: protectedProcessIDs(),
            readIdentity: readIdentity,
            readListeners: { ListeningPortScanner.scan() },
            sendSignal: { kill($0, $1) },
            shouldContinue: { !Task.isCancelled }
        )
        guard operations.shouldContinue() else { return .failure(.cancelled) }
        guard let expected = target.identity, expected.process.processIdentifier == target.item.pid else {
            return .failure(.identityUnavailable)
        }
        if let error = protectionError(identity: expected, currentUserID: operations.currentUserID, protectedProcessIDs: operations.protectedProcessIDs) {
            return .failure(error)
        }
        guard operations.readIdentity(target.item.pid) == expected else { return .failure(.identityChanged) }
        let listeners = operations.readListeners()
        guard operations.shouldContinue() else { return .failure(.cancelled) }
        guard listeners.contains(where: { $0.pid == target.item.pid && $0.port == target.item.port && $0.address == target.item.address }) else {
            return .failure(.listenerNotVerified)
        }
        guard operations.readIdentity(target.item.pid) == expected else { return .failure(.identityChanged) }
        guard operations.shouldContinue() else { return .failure(.cancelled) }
        guard operations.sendSignal(target.item.pid, SIGTERM) == 0 else { return .failure(.signalFailed(errno)) }
        return .success(())
    }

    static func protectionError(identity: Identity, currentUserID: uid_t, protectedProcessIDs: Set<pid_t>) -> ListeningPortTerminationError? {
        let processID = identity.process.processIdentifier
        let path = identity.executablePath
        guard processID > 1, !protectedProcessIDs.contains(processID), identity.effectiveUserID != 0,
              identity.effectiveUserID == currentUserID, identity.realUserID == currentUserID,
              path.hasPrefix("/"), identity.process.startTimeSeconds > 0 else { return .protectedProcess }
        let systemPath = path.hasPrefix("/System/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/")
            || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/"))
        if systemPath { return .protectedProcess }
        return path.contains(".app/Contents/") ? .runningApplication : nil
    }

    private static func readProcessInfo(_ processID: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(processID), info.pbi_status != SZOMB else { return nil }
        return info
    }

    private static func readIdentity(_ processID: pid_t) -> Identity? {
        guard processID > 0, let info = readProcessInfo(processID) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        let pathLength = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0, let finalInfo = readProcessInfo(processID),
              RunningAppsMonitor.identity(processIdentifier: processID, info: info) == RunningAppsMonitor.identity(processIdentifier: processID, info: finalInfo),
              info.pbi_uid == finalInfo.pbi_uid, info.pbi_ruid == finalInfo.pbi_ruid else { return nil }
        return Identity(
            process: RunningAppsMonitor.identity(processIdentifier: processID, info: info),
            effectiveUserID: info.pbi_uid,
            realUserID: info.pbi_ruid,
            executablePath: String(cString: path)
        )
    }

    private static func processIdentities() -> [pid_t: RunningAppIdentity] {
        let capacity = max(0, Int(proc_listallpids(nil, 0))) + 128
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let count = processIDs.withUnsafeMutableBytes { buffer in proc_listallpids(buffer.baseAddress, Int32(buffer.count)) }
        guard count > 0 else { return [:] }
        var identities: [pid_t: RunningAppIdentity] = [:]
        for processID in processIDs.prefix(min(Int(count), capacity)) where processID > 0 {
            guard !Task.isCancelled else { return [:] }
            if let info = readProcessInfo(processID) {
                identities[processID] = RunningAppsMonitor.identity(processIdentifier: processID, info: info)
            }
        }
        return identities
    }

    private static func protectedProcessIDs() -> Set<pid_t> {
        var protected: Set<pid_t> = [1, getpid()]
        var processID = getpid()
        while let info = readProcessInfo(processID), info.pbi_ppid > 1 {
            processID = pid_t(info.pbi_ppid)
            guard protected.insert(processID).inserted else { break }
        }
        return protected
    }
}

enum PeripheralBatteryScanner {
    static func scanAll(shouldContinue: @Sendable () -> Bool = { !Task.isCancelled }) -> [WirelessPeripheralBattery] {
        var results: [WirelessPeripheralBattery] = []
        var seenIDs = Set<String>()

        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            guard let matching = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                guard shouldContinue() else { return [] }
                let entry = IOIteratorNext(iterator)
                guard entry != 0 else { break }
                defer { IOObjectRelease(entry) }

                var unmanagedProps: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &unmanagedProps, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                      let props = unmanagedProps?.takeRetainedValue() as? [String: Any] else { continue }
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == kIOReturnSuccess,
                      let battery = battery(properties: props, registryID: registryID),
                      seenIDs.insert(battery.id).inserted else { continue }
                results.append(battery)
            }
        }
        return results.sorted {
            if $0.percent != $1.percent { return $0.percent < $1.percent }
            return $0.id < $1.id
        }
    }

    static func battery(properties props: [String: Any], registryID: UInt64) -> WirelessPeripheralBattery? {
        guard (props["Connected"] as? Bool) != false,
              (props["Built-In"] as? Bool) != true,
              let percent = props["BatteryPercent"] as? NSNumber,
              CFGetTypeID(percent) != CFBooleanGetTypeID(),
              percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue) else { return nil }
        let transport = (props["Transport"] as? String)?.lowercased() ?? ""
        guard !["spi", "i2c", "built-in"].contains(transport) else { return nil }
        let rawName = (props["Product"] as? String)
            ?? (props["Product Name"] as? String)
            ?? (props["Bluetooth Product Name"] as? String)
            ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let address = ((props["DeviceAddress"] as? String) ?? (props["BluetoothDeviceAddress"] as? String) ?? "")
            .lowercased().filter { $0.isHexDigit }
        let serial = (props["SerialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identity = address.count == 12 ? "bluetooth:\(address)" : (!serial.isEmpty ? "serial:\(serial)" : "registry:\(registryID)")

        let lower = trimmed.lowercased()
        let symbol: String
        if lower.contains("keyboard") || lower.contains("键盘") {
            symbol = "keyboard"
        } else if lower.contains("trackpad") || lower.contains("触控板") {
            symbol = "rectangle.and.hand.point.up.left"
        } else if lower.contains("airpods") || lower.contains("headphone") || lower.contains("ear") || lower.contains("耳机") {
            symbol = "airpodspro"
        } else {
            symbol = "computermouse"
        }
        return WirelessPeripheralBattery(id: identity, name: trimmed, symbol: symbol, percent: Int(percent.doubleValue.rounded()))
    }

    static func merging(hid: [WirelessPeripheralBattery], gHub: GHubMouseBattery?) -> [WirelessPeripheralBattery] {
        guard let gHub else { return hid }
        let clampedPercent = min(max(gHub.percent, 0), 100)
        let trimmedName = gHub.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "罗技无线鼠标" : trimmedName
        var merged = hid
        if let idx = merged.firstIndex(where: {
            $0.name.localizedCaseInsensitiveContains(displayName) || displayName.localizedCaseInsensitiveContains($0.name)
        }) {
            let existing = merged[idx]
            merged[idx] = WirelessPeripheralBattery(
                id: existing.id,
                name: existing.name,
                symbol: existing.symbol,
                percent: clampedPercent,
                isCharging: gHub.isCharging
            )
        } else {
            merged.append(WirelessPeripheralBattery(
                id: "ghub:\(displayName.lowercased())",
                name: displayName,
                symbol: "computermouse",
                percent: clampedPercent,
                isCharging: gHub.isCharging
            ))
        }
        return merged.sorted {
            if $0.percent != $1.percent { return $0.percent < $1.percent }
            return $0.id < $1.id
        }
    }
}

final class WirelessPeripheralBatteryReader: @unchecked Sendable {
    static let scanInterval: TimeInterval = 30

    private let lock = NSLock()
    private let gHubReader: GHubBatteryReader
    private var cachedDevices: [WirelessPeripheralBattery] = []
    private var hasPrimedHID = false
    private var isScanning = false
    private var nextScanDate = Date.distantPast

    init(gHubReader: GHubBatteryReader = GHubBatteryReader()) {
        self.gHubReader = gHubReader
    }

    func snapshot() -> [WirelessPeripheralBattery] {
        lock.lock()
        let needsPrime = !hasPrimedHID
        let shouldScan = !isScanning && Date() >= nextScanDate
        if shouldScan {
            isScanning = true
            nextScanDate = Date().addingTimeInterval(Self.scanInterval)
        }
        var result = cachedDevices
        lock.unlock()

        if needsPrime {
            let initialHID = PeripheralBatteryScanner.scanAll()
            lock.lock()
            if !hasPrimedHID {
                cachedDevices = initialHID
                hasPrimedHID = true
            }
            result = cachedDevices
            lock.unlock()
        }

        if shouldScan {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let scanned = self.scanPeripherals()
                self.lock.lock()
                self.cachedDevices = scanned
                self.hasPrimedHID = true
                self.isScanning = false
                self.lock.unlock()
            }
        }
        return result
    }

    func forceRefresh(completion: (@Sendable ([WirelessPeripheralBattery]) -> Void)? = nil) {
        lock.lock()
        guard !isScanning else {
            let current = cachedDevices
            lock.unlock()
            completion?(current)
            return
        }
        isScanning = true
        nextScanDate = Date().addingTimeInterval(Self.scanInterval)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scanned = self.scanPeripherals()
            self.lock.lock()
            self.cachedDevices = scanned
            self.hasPrimedHID = true
            self.isScanning = false
            self.lock.unlock()
            completion?(scanned)
        }
    }

    private func scanPeripherals() -> [WirelessPeripheralBattery] {
        let hid = PeripheralBatteryScanner.scanAll()
        let gHub = gHubReader.read()
        return PeripheralBatteryScanner.merging(hid: hid, gHub: gHub)
    }
}
