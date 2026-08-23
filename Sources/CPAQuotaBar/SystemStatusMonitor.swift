import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

final class SystemStatusMonitor: @unchecked Sendable {
    /// 鼠标电量读取频率：频繁向 HID/罗技服务查询会不断唤醒无线鼠标，耗电明显，
    /// 因此按用户要求低频读取（每天约两次）。
    private static let mouseBatteryCacheInterval: TimeInterval = 12 * 3600

    private let lock = NSLock()
    private var previousCPUTicks: (used: UInt64, total: UInt64)?
    private var previousNetworkBytes: (in: UInt64, out: UInt64, time: CFAbsoluteTime)?
    private var previousBatterySampleTime: CFAbsoluteTime = 0
    private var batteryStateCache: (level: Double, info: String)?
    private var previousMouseBatterySampleTime: CFAbsoluteTime = 0
    private var mouseBatteryCache: (level: Double?, text: String, raw: String)?
    private var mouseBatteryReadFailed = false
    private var cycleCountCache: (count: Int, sampledAt: CFAbsoluteTime)?
    private var powerScale = PowerScale()
    private let smc = AppleSMC()
    // 读取器全局共享：菜单栏与弹窗页各有一个监视器实例，
    // 共享后鼠标电量与附近设备扫描的缓存也全局生效，避免双倍轮询。
    private static let sharedGHubBatteryReader = GHubBatteryReader()
    private static let sharedAppleDeviceBatteryReader = AppleDeviceBatteryReader()
    private var gHubBatteryReader: GHubBatteryReader { Self.sharedGHubBatteryReader }
    private var appleDeviceBatteryReader: AppleDeviceBatteryReader { Self.sharedAppleDeviceBatteryReader }

    /// 菜单栏专用轻量采样：只读取电量、功率与缓存的鼠标电量，
    /// 跳过 CPU/GPU/内存/磁盘/网络采样和附近设备扫描。
    /// 菜单栏数字 24 小时驻留，这里省掉的开销就是后台的持续开销。
    func sampleMenuBar() -> SystemStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = CFAbsoluteTimeGetCurrent()
        let mouseBattery = readMouseBattery(currentTime: currentTime)
        let fallbackWatts = readPower()
        let powerFlow = readPowerFlow(
            cpu: nil,
            gpu: nil,
            fallbackWatts: fallbackWatts,
            nearbyDevices: [],
            skipPackData: true
        )
        let metrics = [
            SystemMetric(kind: .mouseBattery, title: "鼠标", detail: mouseBattery.text, value: mouseBattery.level, rawString: mouseBattery.raw, accessibilityHelp: "已连接鼠标的剩余电量")
        ]
        return SystemStatusSnapshot(metrics: metrics, powerFlow: powerFlow)
    }

    func sample(includeBatteryPackDetail: Bool = true) -> SystemStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let currentTime = CFAbsoluteTimeGetCurrent()
        let cpu = readCPUUsage()
        let memory = readMemoryUsage()
        let disk = readDiskUsage()
        let gpu = readGPUMemoryPressure()
        let fallbackWatts = readPower()
        let network = readNetworkUsage(currentTime: currentTime)
        let battery = readBattery(currentTime: currentTime)
        let mouseBattery = readMouseBattery(currentTime: currentTime)
        let powerFlow = readPowerFlow(
            cpu: cpu,
            gpu: gpu,
            fallbackWatts: fallbackWatts,
            nearbyDevices: appleDeviceBatteryReader.snapshot(),
            skipPackData: !includeBatteryPackDetail
        )
        // AppleSmartBattery 的 SystemPowerIn 是当前系统实际功耗，优先于部分机型上
        // 只代表功率上限/设计值的 SMC PDTR、PSTR。这样状态页的“功率”也会随负载实时变化。
        let watts = powerFlow.systemWatts ?? fallbackWatts

        var metrics = [
            SystemMetric(kind: .cpu, title: "CPU", detail: percent(cpu), value: cpu, rawString: cpu.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "所有处理器核心当前总使用率"),
            SystemMetric(kind: .gpu, title: "GPU", detail: percent(gpu), value: gpu, rawString: gpu.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "图形处理器当前设备利用率"),
            SystemMetric(kind: .memory, title: "内存", detail: memory.map { "已用 \(percent($0))" } ?? "不可用", value: memory, rawString: memory.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "物理内存当前使用比例"),
            SystemMetric(kind: .disk, title: "磁盘", detail: disk.map { "已用 \(percent($0))" } ?? "不可用", value: disk, rawString: disk.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "启动磁盘已使用容量比例"),
            SystemMetric(kind: .power, title: "功率", detail: watts.map { String(format: "%.1f W", $0) } ?? "不可用", value: watts.map { powerScale.normalized($0) }, rawString: watts.map { String(format: "%.1fW", $0) }, accessibilityHelp: "Apple 电源遥测中的当前系统实际功耗")
        ]

        metrics.append(SystemMetric(kind: .network, title: "网络", detail: network.text, value: nil, rawString: network.raw, accessibilityHelp: "非本地回环网口总上下行速率"))
        metrics.append(SystemMetric(kind: .battery, title: "电池", detail: battery.text, value: battery.level, rawString: battery.raw, accessibilityHelp: "设备内置电池当前剩余电量与健康状态"))
        metrics.append(SystemMetric(kind: .mouseBattery, title: "鼠标", detail: mouseBattery.text, value: mouseBattery.level, rawString: mouseBattery.raw, accessibilityHelp: "已连接鼠标的剩余电量"))

        return SystemStatusSnapshot(metrics: metrics, powerFlow: powerFlow)
    }

    func resetTransientState() {
        lock.lock()
        previousCPUTicks = nil
        previousNetworkBytes = nil
        batteryStateCache = nil
        previousBatterySampleTime = 0
        // 鼠标电量缓存不在此清除：关闭面板不应触发对鼠标的额外读取。
        lock.unlock()
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "不可用" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func readCPUUsage() -> Double? {
        var cpuInfo: processor_info_array_t?
        var cpuCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &cpuInfo, &cpuCount)
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(cpuCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        var used: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(processorCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            used += user + system + nice
            total += user + system + nice + idle
        }
        defer { previousCPUTicks = (used, total) }
        guard let previousCPUTicks, total > previousCPUTicks.total else { return 0 }
        return Double(used - previousCPUTicks.used) / Double(total - previousCPUTicks.total)
    }

    private func readMemoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSizeValue: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSizeValue) == KERN_SUCCESS else { return nil }
        let pageSize = Double(pageSizeValue)
        let usedPages = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(usedPages * pageSize / total, 1) : nil
    }

    private func readDiskUsage() -> Double? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0 else { return nil }
        return min(max(1 - Double(available) / Double(total), 0), 1)
    }

    private func readGPUMemoryPressure() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var maximum: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let properties = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            for key in ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %"] {
                if let value = properties[key] as? NSNumber {
                    maximum = max(maximum ?? 0, value.doubleValue / 100)
                }
            }
        }
        return maximum.map { min(max($0, 0), 1) }
    }

    private func readPower() -> Double? {
        if let direct = smc?.readNumber("PDTR"), direct.isFinite, direct >= 0 { return direct }
        if let system = smc?.readNumber("PSTR"), system.isFinite, system >= 0 { return system }
        if let voltage = smc?.readNumber("VD0R"), let current = smc?.readNumber("ID0R") {
            let watts = voltage * current
            if watts.isFinite, watts >= 0 { return watts }
        }
        return nil
    }

    private func readNetworkUsage(currentTime: CFAbsoluteTime) -> (text: String, raw: String) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ("获取失败", "") }
        defer { freeifaddrs(ifaddr) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr!.pointee

            guard let namePtr = interface.ifa_name else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("lo") { continue }

            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_LINK) {
                guard let data = interface.ifa_data else { continue }
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                inBytes += UInt64(networkData.ifi_ibytes)
                outBytes += UInt64(networkData.ifi_obytes)
            }
        }

        let timeDelta = previousNetworkBytes.map { currentTime - $0.time } ?? 0
        let inDelta = previousNetworkBytes.map { inBytes >= $0.in ? inBytes - $0.in : 0 } ?? 0
        let outDelta = previousNetworkBytes.map { outBytes >= $0.out ? outBytes - $0.out : 0 } ?? 0

        previousNetworkBytes = (inBytes, outBytes, currentTime)

        guard timeDelta > 0 else { return ("计算中...", "") }

        let inSpeed = Double(inDelta) / timeDelta
        let outSpeed = Double(outDelta) / timeDelta

        func formatSpeed(_ bytesPerSecond: Double) -> String {
            if bytesPerSecond > 1024 * 1024 * 1024 {
                return String(format: "%.2f GB/s", bytesPerSecond / (1024 * 1024 * 1024))
            } else if bytesPerSecond > 1024 * 1024 {
                return String(format: "%.2f MB/s", bytesPerSecond / (1024 * 1024))
            } else if bytesPerSecond > 1024 {
                return String(format: "%.2f KB/s", bytesPerSecond / 1024)
            } else {
                return String(format: "%.0f B/s", bytesPerSecond)
            }
        }

        let downText = formatSpeed(inSpeed)
        let upText = formatSpeed(outSpeed)
        return ("↓ \(downText)  ↑ \(upText)", "\(downText)/\(upText)")
    }

    private func readBattery(currentTime: CFAbsoluteTime) -> (level: Double?, text: String, raw: String) {
        if let cached = batteryStateCache, currentTime - previousBatterySampleTime < 5.0 {
            return (cached.level, cached.info, "\(Int(cached.level * 100))%")
        }

        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for ps in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(snapshot, ps),
                  let info = unmanaged.takeUnretainedValue() as? [String: Any] else { continue }
            guard let isPresent = info[kIOPSIsPresentKey] as? Bool, isPresent else { continue }
            guard let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = info[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0 else { continue }

            let level = Double(currentCapacity) / Double(maxCapacity)
            guard level.isFinite else { continue }
            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            var textParts = ["\(Int(level * 100))%"]
            if isCharging {
                textParts.append("充电中")
            } else {
                textParts.append("未充电")
            }

            if let cycleCount = getBatteryCycleCount() {
                textParts.append("循环: \(cycleCount)")
            }

            let text = textParts.joined(separator: " ")
            batteryStateCache = (level, text)
            previousBatterySampleTime = currentTime
            return (level, text, "\(Int(level * 100))%")
        }

        return (nil, "电池不可用", "")
    }

    private func readPowerFlow(
        cpu: Double?,
        gpu: Double?,
        fallbackWatts: Double?,
        nearbyDevices: [NearbyAppleDeviceBattery],
        skipPackData: Bool = false
    ) -> PowerFlowSnapshot {
        guard let properties = smartBatteryProperties() else {
            let systemWatts = fallbackWatts
            let split = estimatedLoadSplit(systemWatts: systemWatts, cpu: cpu, gpu: gpu)
            return PowerFlowSnapshot(
                batteryLevel: nil,
                isCharging: false,
                externalConnected: false,
                chargeLimitPercent: nil,
                adapterWatts: nil,
                inputWatts: systemWatts,
                systemWatts: systemWatts,
                batteryWatts: nil,
                cpuWatts: split.cpu,
                gpuWatts: split.gpu,
                otherWatts: split.other,
                temperatureCelsius: nil,
                timeToFullMinutes: nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                nearbyDevices: nearbyDevices,
                sampledAt: Date()
            )
        }

        let currentCapacity = number(in: properties, key: "CurrentCapacity")
        let maxCapacity = number(in: properties, key: "MaxCapacity")
        let batteryLevel: Double?
        if let currentCapacity, let maxCapacity, maxCapacity > 0 {
            batteryLevel = min(max(currentCapacity / maxCapacity, 0), 1)
        } else {
            batteryLevel = nil
        }

        let batteryData = dictionary(in: properties, key: "BatteryData")
        // 电池包属性（温度、充电上限）只用于电源页；菜单栏轻量采样跳过这次 IORegistry 读取。
        let packData = skipPackData ? [:] : smartBatteryPackData()
        let telemetry = dictionary(in: properties, key: "PowerTelemetryData")
        let distribution = dictionary(in: properties, key: "PowerDistribution")
        let adapter = dictionary(in: properties, key: "AdapterDetails")

        // SystemPowerIn / IPDInputPower 在部分 Apple Silicon 机型上是低频缓存值。
        // SMC 的 PDTR 是当前 DC 输入功率，应优先用于实时页面和菜单栏显示。
        let telemetrySystemWatts = milliwatts(in: telemetry, key: "SystemPowerIn")
        let distributionInputWatts = milliwatts(in: distribution, key: "IPDInputPower")
        let systemWatts = fallbackWatts ?? telemetrySystemWatts
        let inputWatts = systemWatts ?? distributionInputWatts
        let isCharging = bool(in: properties, key: "IsCharging")
        let externalConnected = bool(in: properties, key: "ExternalConnected")
        let telemetryBatteryWatts = milliwatts(in: telemetry, key: "BatteryPower")
            ?? milliwatts(in: batteryData, key: "BatteryPower")
        let electricalBatteryWatts: Double? = {
            guard let amperage = number(in: properties, key: "Amperage"),
                  let voltage = number(in: properties, key: "Voltage") else { return nil }
            let watts = amperage * voltage / 1_000_000
            return watts.isFinite ? watts : nil
        }()
        let batteryWatts: Double? = {
            if let telemetryBatteryWatts, abs(telemetryBatteryWatts) >= 0.05 {
                // BatteryPower 在不同机型上有时只给功率大小，不保留方向。
                // 用 IsCharging / ExternalConnected 统一成“充电为正、放电为负”，
                // 否则插电但电池辅助供电时会被错判为待机。
                if isCharging { return abs(telemetryBatteryWatts) }
                if !externalConnected { return -abs(telemetryBatteryWatts) }
                if let electricalBatteryWatts {
                    if electricalBatteryWatts < -0.05 {
                        return -abs(telemetryBatteryWatts)
                    }
                    // 电流为零时 BatteryPower 可能是上次样本，不用它制造假流向。
                    if abs(electricalBatteryWatts) <= 0.05 { return 0 }
                    return electricalBatteryWatts
                }
                // 插电、未充电且电池有非零功率，在无电流方向时按辅助放电降级处理。
                return -abs(telemetryBatteryWatts)
            }
            return electricalBatteryWatts ?? telemetryBatteryWatts
        }()
        let split = estimatedLoadSplit(systemWatts: systemWatts, cpu: cpu, gpu: gpu)

        let rawTemperature = number(in: packData, key: "Temperature")
            ?? number(in: batteryData, key: "Temperature")
        let temperature = rawTemperature.flatMap { value -> Double? in
            let celsius = value > 1000 ? value / 100 : value / 10
            return (-20...100).contains(celsius) ? celsius : nil
        }

        let rawMinutes = number(in: properties, key: "AvgTimeToFull")
            ?? number(in: properties, key: "TimeRemaining")
        let timeToFull = rawMinutes.flatMap { value -> Int? in
            guard value >= 0, value < 65_535 else { return nil }
            return Int(value.rounded())
        }

        let configuredLimit = number(in: packData, key: "DailyMaxSoc")
            ?? number(in: batteryData, key: "DailyMaxSoc")
        let inferredLimit: Double? = {
            guard bool(in: properties, key: "ExternalConnected"),
                  !bool(in: properties, key: "IsCharging"),
                  let batteryLevel,
                  batteryLevel < 0.99 else { return nil }
            return (batteryLevel * 100).rounded()
        }()
        let limit = (configuredLimit ?? inferredLimit)
            .map { Int(min(max($0, 0), 100).rounded()) }

        return PowerFlowSnapshot(
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            externalConnected: externalConnected,
            chargeLimitPercent: limit,
            adapterWatts: number(in: adapter, key: "Watts"),
            inputWatts: inputWatts,
            systemWatts: systemWatts,
            batteryWatts: batteryWatts,
            cpuWatts: split.cpu,
            gpuWatts: split.gpu,
            otherWatts: split.other,
            temperatureCelsius: temperature,
            timeToFullMinutes: timeToFull,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            nearbyDevices: nearbyDevices,
            sampledAt: Date()
        )
    }

    private func smartBatteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    private func smartBatteryPackData() -> [String: Any] {
        guard let matching = IOServiceMatching("AppleSmartBatteryPack") else { return [:] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dictionary(in: properties, key: "BatteryData")
    }

    private func estimatedLoadSplit(
        systemWatts: Double?,
        cpu: Double?,
        gpu: Double?
    ) -> (cpu: Double?, gpu: Double?, other: Double?) {
        guard let systemWatts, systemWatts.isFinite, systemWatts >= 0 else {
            return (nil, nil, nil)
        }
        let cpuWeight = 0.28 + min(max(cpu ?? 0, 0), 1) * 0.72
        let gpuWeight = 0.12 + min(max(gpu ?? 0, 0), 1) * 0.88
        let otherWeight = 0.56
        let total = cpuWeight + gpuWeight + otherWeight
        return (
            systemWatts * cpuWeight / total,
            systemWatts * gpuWeight / total,
            systemWatts * otherWeight / total
        )
    }

    private func dictionary(in properties: [String: Any], key: String) -> [String: Any] {
        properties[key] as? [String: Any] ?? [:]
    }

    private func number(in properties: [String: Any], key: String) -> Double? {
        (properties[key] as? NSNumber)?.doubleValue
    }

    private func bool(in properties: [String: Any], key: String) -> Bool {
        (properties[key] as? NSNumber)?.boolValue
            ?? (properties[key] as? Bool)
            ?? false
    }

    private func milliwatts(in properties: [String: Any], key: String) -> Double? {
        guard let value = number(in: properties, key: key), value.isFinite else { return nil }
        // 负值有时会以无符号 64 位补码暴露；这种值不适合作为界面读数。
        guard value >= 0, value < 1_000_000_000 else { return nil }
        return value / 1_000
    }

    private func getBatteryCycleCount() -> Int? {
        // 循环次数只在完整充放电周期后变化，缓存 12 小时足够，
        // 避免状态页打开期间每 5 秒枚举一次 IORegistry。
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cycleCountCache, now - cached.sampledAt < 12 * 3600 {
            return cached.count
        }
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            if let properties = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                cycleCountCache = (properties.intValue, now)
                return properties.intValue
            }
        }
        return nil
    }

    private func readMouseBattery(currentTime: CFAbsoluteTime) -> (level: Double?, text: String, raw: String) {
        // 读取成功后 12 小时内直接用缓存；仅在没读到鼠标时用较短间隔重试，
        // 避免鼠标暂时断开导致长时间显示“未检测到电量”。失败重试也保持低频，
        // 因为每次重试都是一次全量 IORegistry 递归扫描。
        let retryInterval: TimeInterval = mouseBatteryReadFailed ? 60 * 60 : Self.mouseBatteryCacheInterval
        if let cached = mouseBatteryCache, currentTime - previousMouseBatterySampleTime < retryInterval {
            return cached
        }

        if let gHubBattery = gHubBatteryReader.read() {
            let charging = gHubBattery.isCharging ? " 充电中" : ""
            let value = (
                level: Double(gHubBattery.percent) / 100,
                text: "\(gHubBattery.percent)%\(charging) \(gHubBattery.name)",
                raw: "\(gHubBattery.percent)%"
            )
            mouseBatteryCache = value
            mouseBatteryReadFailed = false
            previousMouseBatterySampleTime = currentTime
            return value
        }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return cacheMouseBattery(nil, currentTime: currentTime) }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, options, &iterator) == kIOReturnSuccess else {
            return cacheMouseBattery(nil, currentTime: currentTime)
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [(name: String, percent: Int)] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanagedProperties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
                  let percentNumber = properties["BatteryPercent"] as? NSNumber else { continue }

            let percent = min(max(percentNumber.intValue, 0), 100)
            let name = Self.mouseProductName(in: properties)
            let primaryUsage = (properties["PrimaryUsage"] as? NSNumber)?.intValue
            guard primaryUsage == 2 || Self.looksLikeMouse(name) else { continue }
            candidates.append((name ?? "鼠标", percent))
        }

        let selected = candidates.min { lhs, rhs in lhs.percent < rhs.percent }
        return cacheMouseBattery(selected, currentTime: currentTime)
    }

    private func cacheMouseBattery(
        _ candidate: (name: String, percent: Int)?,
        currentTime: CFAbsoluteTime
    ) -> (level: Double?, text: String, raw: String) {
        let value: (level: Double?, text: String, raw: String)
        if let candidate {
            value = (
                Double(candidate.percent) / 100,
                "\(candidate.percent)% \(candidate.name)",
                "\(candidate.percent)%"
            )
        } else {
            value = (nil, "未检测到电量", "")
        }
        mouseBatteryCache = value
        mouseBatteryReadFailed = candidate == nil
        previousMouseBatterySampleTime = currentTime
        return value
    }

    private static func mouseProductName(in properties: [String: Any]) -> String? {
        for key in ["Product", "Product Name", "USB Product Name", "Bluetooth Product Name"] {
            if let value = properties[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func looksLikeMouse(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return ["mouse", "trackball", "mx master", "mx anywhere", "鼠标"].contains {
            name.contains($0)
        }
    }
}

private final class AppleSMC {
    private var connection: io_connect_t = 0

    init?() {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func readNumber(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        input.data8 = 9
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let size = Int(output.keyInfo.dataSize)
        let type = output.keyInfo.dataType.smcString
        guard size > 0, size <= 32 else { return nil }
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5
        output = SMCKeyData()
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return decode(type: type, bytes: bytes)
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let size = MemoryLayout<SMCKeyData>.stride
        var outputSize = size
        return IOConnectCallStructMethod(connection, 2, &input, size, &output, &outputSize)
    }

    private func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> UInt16? { bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil }
        func be32() -> UInt32? { bytes.count >= 4 ? UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) : nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return bytes.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return be16().map(Double.init)
        case "ui32": return be32().map(Double.init)
        case "sp78": return be16().map { Double(Int16(bitPattern: $0)) / 256 }
        case "sp87": return be16().map { Double(Int16(bitPattern: $0)) / 128 }
        case "sp96": return be16().map { Double(Int16(bitPattern: $0)) / 64 }
        case "fpe2": return be16().map { Double($0 >> 2) }
        default: return nil
        }
    }
}

private extension UInt32 {
    var smcString: String {
        String(bytes: [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)], encoding: .ascii) ?? ""
    }
}

private struct SMCKeyData {
    struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: IOByteCount32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
