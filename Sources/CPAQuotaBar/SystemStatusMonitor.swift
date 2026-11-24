import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

final class SystemStatusMonitor: @unchecked Sendable {
    /// 鼠标电量读取频率：频繁向 HID/罗技服务查询会不断唤醒无线鼠标，耗电明显，
    /// 因此按用户要求低频读取（每天约两次）。
    private static let mouseBatteryCacheInterval: TimeInterval = 12 * 3600
    private static let hostPort: mach_port_t = mach_host_self()
    private static let pageSizeBytes: Double = {
        var size: vm_size_t = 0
        if host_page_size(hostPort, &size) == KERN_SUCCESS, size > 0 {
            return Double(size)
        }
        return 16_384
    }()

    private let lock = NSLock()
    private var previousCPUTicks: (used: UInt64, total: UInt64)?
    private var previousNetworkBytes: (in: UInt64, out: UInt64, time: CFAbsoluteTime)?
    private var previousSwapCounters: (ins: UInt64, outs: UInt64, time: CFAbsoluteTime)?
    private var diskUsageCache: (usedFraction: Double, freeBytes: Int64, purgeableBytes: Int64, totalBytes: Int64, sampledAt: CFAbsoluteTime)?
    private var powerScale = PowerScale()
    private var networkScaleWattsEquivalent = PowerScale()

    private static let cpuTopologyTag: String? = {
        func readInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }
        if let p = readInt("hw.perflevel0.physicalcpu"), let e = readInt("hw.perflevel1.physicalcpu") {
            return "\(p)P+\(e)E"
        }
        return nil
    }()

    // 读取器全局共享：菜单栏与弹窗页各有一个监视器实例，
    // 共享后鼠标电量与附近设备扫描的缓存也全局生效，避免双倍轮询。
    private static let sharedSMC = AppleSMC()
    private static let sharedGHubBatteryReader = GHubBatteryReader()
    private static let sharedAppleDeviceBatteryReader = AppleDeviceBatteryReader()
    private static let sharedPeripheralBatteryReader = WirelessPeripheralBatteryReader(gHubReader: sharedGHubBatteryReader)
    private static let sharedMouseBatteryCache = SharedMouseBatteryCache()

    private var smc: AppleSMC? { Self.sharedSMC }
    private var gHubBatteryReader: GHubBatteryReader { Self.sharedGHubBatteryReader }
    private var appleDeviceBatteryReader: AppleDeviceBatteryReader { Self.sharedAppleDeviceBatteryReader }
    private var peripheralBatteryReader: WirelessPeripheralBatteryReader { Self.sharedPeripheralBatteryReader }

    static func refreshNearbyDevices(completion: (@Sendable ([NearbyAppleDeviceBattery]) -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        sharedPeripheralBatteryReader.forceRefresh { _ in group.leave() }
        group.enter()
        let box = NearbyRefreshBox()
        sharedAppleDeviceBatteryReader.forceRefresh { devices in
            box.store(devices)
            group.leave()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion?(box.load())
        }
    }

    /// 菜单栏专用按需采样：只读取用户当前勾选的线条或数字所需指标，不做任何多余系统调用。
    func sampleMenuBarUsage(
        lines: [MenuBarLineOption] = MenuBarLineOption.savedSelection(),
        numbers: Set<MenuBarNumberOption> = MenuBarNumberOption.savedSelection()
    ) -> [SystemMetric] {
        lock.lock()
        defer { lock.unlock() }
        let wantsCPU = lines.contains(.cpu) || numbers.contains(.cpu)
        let wantsGPU = lines.contains(.gpu)
        let wantsMemory = lines.contains(.memory) || numbers.contains(.memory)
        let wantsDisk = lines.contains(.disk)
        let wantsThermal = lines.contains(.cpuTemp) || numbers.contains(.cpuTemp)
        let wantsNetwork = numbers.contains(.network)

        var result: [SystemMetric] = []
        if wantsCPU {
            let cpu = readCPUUsage()
            result.append(SystemMetric(kind: .cpu, title: "CPU", detail: "", value: cpu, rawString: cpu.map { "\(Int(($0 * 100).rounded()))%" }, accessibilityHelp: "CPU 使用率"))
        }
        if wantsGPU {
            let gpu = readGPUStats().utilization
            result.append(SystemMetric(kind: .gpu, title: "GPU", detail: "", value: gpu, rawString: nil, accessibilityHelp: "GPU 使用率"))
        }
        if wantsMemory {
            let mem = readMemoryDetails()?.fraction
            result.append(SystemMetric(kind: .memory, title: "内存", detail: "", value: mem, rawString: mem.map { "\(Int(($0 * 100).rounded()))%" }, accessibilityHelp: "内存使用率"))
        }
        if wantsDisk {
            let disk = readDiskDetails(currentTime: CFAbsoluteTimeGetCurrent())?.usedFraction
            result.append(SystemMetric(kind: .disk, title: "磁盘", detail: "", value: disk, rawString: nil, accessibilityHelp: "磁盘使用率"))
        }
        if wantsThermal {
            let temp = smc?.readCPUTemperature()
            let normalized = temp.map { min(max(($0 - 30) / 70, 0), 1) }
            result.append(SystemMetric(kind: .thermal, title: "散热", detail: "", value: normalized, rawString: temp.map { "\(Int($0.rounded()))°C" }, accessibilityHelp: "CPU 温度"))
        }
        if wantsNetwork {
            let net = readNetworkUsage(currentTime: CFAbsoluteTimeGetCurrent())
            result.append(SystemMetric(kind: .network, title: "网络", detail: net.text, value: net.level, rawString: net.compactDown, accessibilityHelp: "实时网速"))
        }
        return result
    }

    func sampleMenuBar() -> SystemStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = CFAbsoluteTimeGetCurrent()
        let mouseBattery = readMouseBattery(currentTime: currentTime)
        let smartProps = smartBatteryProperties()
        let fallbackWatts = readPower(from: smartProps)
        let powerFlow = readPowerFlow(
            properties: smartProps,
            cpu: nil,
            gpu: nil,
            cpuTemperature: smc?.readCPUTemperature(),
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
        let memoryInfo = readMemoryDetails()
        let memory = memoryInfo?.fraction
        let diskInfo = readDiskDetails(currentTime: currentTime)
        let disk = diskInfo?.usedFraction
        let gpuStats = readGPUStats()
        let gpu = gpuStats.utilization
        let smartProps = smartBatteryProperties()
        let fallbackWatts = readPower(from: smartProps)
        let network = readNetworkUsage(currentTime: currentTime)
        let mouseBattery = readMouseBattery(currentTime: currentTime)
        let cpuTemp = smc?.readCPUTemperature()
        let gpuTemp = smc?.readGPUTemperature()
        let fans = smc?.readFanSpeeds() ?? []
        let powerFlow = readPowerFlow(
            properties: smartProps,
            cpu: cpu,
            gpu: gpu,
            cpuTemperature: cpuTemp,
            fallbackWatts: fallbackWatts,
            nearbyDevices: appleDeviceBatteryReader.snapshot(),
            wirelessPeripherals: includeBatteryPackDetail ? peripheralBatteryReader.snapshot() : [],
            skipPackData: !includeBatteryPackDetail
        )
        let battery = formatBatteryMetric(from: powerFlow)
        // AppleSmartBattery 的 SystemPowerIn 是当前系统实际功耗，优先于部分机型上
        // 只代表功率上限/设计值的 SMC PDTR、PSTR。这样状态页的“功率”也会随负载实时变化。
        let watts = powerFlow.systemWatts ?? fallbackWatts
        let loadAvg = readLoadAverage()
        let cpuDetail: String = {
            guard let cpu else { return "不可用" }
            var segs = ["\(Int((cpu * 100).rounded()))%"]
            if let load1 = loadAvg?.0 {
                segs.append(String(format: "负载 %.1f", load1))
            }
            if let topo = Self.cpuTopologyTag {
                segs.append(topo)
            }
            return segs.joined(separator: " · ")
        }()
        let gpuDetail: String = {
            guard let gpu else { return "不可用" }
            if let vram = gpuStats.inUseVRAMBytes, vram > 64 * 1024 * 1024 {
                let gb = Double(vram) / 1_073_741_824
                let vramText = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(vram) / 1_048_576)
                return "\(percent(gpu)) · 显存 \(vramText)"
            }
            return percent(gpu)
        }()
        let memDetail: String = {
            guard let memoryInfo else { return "不可用" }
            let usedGB = Double(memoryInfo.usedBytes) / 1_073_741_824
            let totalGB = Double(memoryInfo.totalBytes) / 1_073_741_824
            return String(format: "%d%% · %.1f/%.0f GB · %@", Int((memoryInfo.fraction * 100).rounded()), usedGB, totalGB, memoryInfo.pressureLabel)
        }()
        let diskDetail: String = {
            guard let diskInfo else { return "不可用" }
            let freeStr = ByteCountFormatter.string(fromByteCount: diskInfo.freeBytes, countStyle: .file)
            if diskInfo.purgeableBytes >= 2_147_483_648 {
                let purgeStr = ByteCountFormatter.string(fromByteCount: diskInfo.purgeableBytes, countStyle: .file)
                return "已用 \(percent(diskInfo.usedFraction)) · 可用 \(freeStr)（含可回收 \(purgeStr)）"
            }
            return "已用 \(percent(diskInfo.usedFraction)) · 剩余 \(freeStr)"
        }()
        let powerDetail: String = {
            guard let watts else { return "不可用" }
            var text = String(format: "%.1f W", watts)
            if powerFlow.externalConnected, let adapter = powerFlow.adapterWatts, adapter > 0 {
                text += String(format: " · PD %.0fW", adapter)
                if adapter < 30 && watts > adapter {
                    text += " ⚠️慢充"
                }
            }
            return text
        }()
        let thermalDetail = formatThermalDetail(cpuTemp: cpuTemp, gpuTemp: gpuTemp, fans: fans)
        let thermalValue = (cpuTemp ?? gpuTemp).map { min(max(($0 - 30) / 70, 0), 1) }

        var metrics = [
            SystemMetric(kind: .cpu, title: "CPU", detail: cpuDetail, value: cpu, rawString: cpu.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "所有处理器核心当前总使用率与 1 分钟系统平均负载；点击查看运行应用"),
            SystemMetric(kind: .gpu, title: "GPU", detail: gpuDetail, value: gpu, rawString: gpu.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "图形处理器当前设备利用率与统一显存占用"),
            SystemMetric(kind: .memory, title: "内存", detail: memDetail, value: memory, rawString: memory.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "物理内存已用容量与系统内存压力；点击查看高内存应用"),
            SystemMetric(kind: .disk, title: "磁盘", detail: diskDetail, value: disk, rawString: disk.map { String(format: "%.1f%%", $0 * 100) }, accessibilityHelp: "启动磁盘已用比例与可用空间；点击前往清理空间"),
            SystemMetric(kind: .power, title: "功率", detail: powerDetail, value: watts.map { powerScale.normalized($0) }, rawString: watts.map { String(format: "%.1fW", $0) }, accessibilityHelp: "Apple 电源遥测中的当前系统实际功耗与 PD 供电握手功率；点击查看电源流向"),
            SystemMetric(kind: .thermal, title: "散热", detail: thermalDetail, value: thermalValue, rawString: cpuTemp.map { String(format: "%.0f°C", $0) }, accessibilityHelp: "处理器核心温度与风扇实时转速")
        ]

        metrics.append(SystemMetric(kind: .network, title: "网络", detail: network.text, value: network.level, rawString: network.raw, accessibilityHelp: "非本地回环网口总上下行速率；点击查看网络详情与自检"))
        metrics.append(SystemMetric(kind: .battery, title: "电池", detail: battery.text, value: battery.level, rawString: battery.raw, accessibilityHelp: "设备内置电池当前剩余电量、健康度与循环次数；点击查看电源详情"))
        metrics.append(SystemMetric(kind: .mouseBattery, title: "鼠标", detail: mouseBattery.text, value: mouseBattery.level, rawString: mouseBattery.raw, accessibilityHelp: "已连接鼠标的剩余电量；点击查看外设与电源详情"))

        let summary = SystemOverviewSummary(
            uptimeSeconds: readSystemUptime(),
            loadAverage1m: loadAvg?.0,
            loadAverage5m: loadAvg?.1,
            localIPAddress: network.localIP,
            interfaceName: network.primaryInterface,
            memoryPressure: memoryInfo?.pressureLabel ?? "正常",
            cpuTemperatureCelsius: cpuTemp,
            gpuTemperatureCelsius: gpuTemp,
            fanSpeedsRPM: fans
        )
        return SystemStatusSnapshot(metrics: metrics, powerFlow: powerFlow, summary: summary)
    }

    func resetTransientState() {
        lock.lock()
        previousCPUTicks = nil
        previousNetworkBytes = nil
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
        let result = host_processor_info(Self.hostPort, PROCESSOR_CPU_LOAD_INFO, &processorCount, &cpuInfo, &cpuCount)
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

    private func readMemoryDetails() -> (fraction: Double, usedBytes: UInt64, totalBytes: UInt64, pressureLabel: String)? {
        guard let comp = sampleMemoryCompositionLocked(currentTime: CFAbsoluteTimeGetCurrent()) else { return nil }
        return (comp.usedFraction, comp.usedBytes, comp.totalBytes, comp.pressureLabel)
    }

    /// 供“内存清理”工作台读取完整的四维物理内存构成、压缩收益与 Swap 读写指标。
    func sampleDetailedMemory() -> MemoryCompositionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return sampleMemoryCompositionLocked(currentTime: CFAbsoluteTimeGetCurrent())
    }

    private func sampleMemoryCompositionLocked(currentTime: CFAbsoluteTime) -> MemoryCompositionSnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(Self.pageSizeBytes)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let uncompressedPages = UInt64(stats.total_uncompressed_pages_in_compressor)
        let cachedPages = UInt64(stats.external_page_count) + purgeablePages
        let freePages = UInt64(stats.free_count)

        let appBytes = min(appPages * page, totalBytes)
        let wiredBytes = min(wiredPages * page, totalBytes)
        let compressedBytes = min(compressedPages * page, totalBytes)
        let uncompressedBytes = uncompressedPages * page
        let cachedBytes = cachedPages * page
        let freeBytes = freePages * page
        let usedBytes = min(appBytes + wiredBytes + compressedBytes, totalBytes)
        let availableBytes = totalBytes > usedBytes ? (totalBytes - usedBytes) : 0

        var pressureLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &size, nil, 0)
        let pressureLabel: String
        switch pressureLevel {
        case 4: pressureLabel = "内存紧张"
        case 2: pressureLabel = "压力偏高"
        case 1: pressureLabel = "正常"
        default: pressureLabel = "暂不可用"
        }

        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0
        let swapUsed = hasSwap ? swapUsage.xsu_used : 0
        let swapTotal = hasSwap ? swapUsage.xsu_total : 0

        let swapIns = stats.swapins
        let swapOuts = stats.swapouts
        var swapInsRate = 0.0
        var swapOutsRate = 0.0
        if let prev = previousSwapCounters, currentTime > prev.time {
            let dt = currentTime - prev.time
            swapInsRate = swapIns >= prev.ins ? Double(swapIns - prev.ins) / dt : 0
            swapOutsRate = swapOuts >= prev.outs ? Double(swapOuts - prev.outs) / dt : 0
        }
        previousSwapCounters = (swapIns, swapOuts, currentTime)

        return MemoryCompositionSnapshot(
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            availableBytes: availableBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            uncompressedInCompressorBytes: uncompressedBytes,
            cachedBytes: cachedBytes,
            freeBytes: freeBytes,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal,
            swapInsPerSecond: swapInsRate,
            swapOutsPerSecond: swapOutsRate,
            pageInsTotal: stats.pageins,
            pageOutsTotal: stats.pageouts,
            pressureLevel: Int(pressureLevel),
            pressureLabel: pressureLabel,
            sampledAt: Date()
        )
    }

    private func readDiskDetails(currentTime: CFAbsoluteTime) -> (usedFraction: Double, freeBytes: Int64, purgeableBytes: Int64, totalBytes: Int64)? {
        if let cached = diskUsageCache, currentTime - cached.sampledAt < 10.0 {
            return (cached.usedFraction, cached.freeBytes, cached.purgeableBytes, cached.totalBytes)
        }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0 else { return nil }
        let strictFree = Int64(values.volumeAvailableCapacity ?? Int(available))
        let purgeable = max(0, available - strictFree)
        let fraction = min(max(1 - Double(available) / Double(total), 0), 1)
        let result = (usedFraction: fraction, freeBytes: available, purgeableBytes: purgeable, totalBytes: Int64(total))
        diskUsageCache = (fraction, available, purgeable, Int64(total), currentTime)
        return result
    }

    private func readGPUStats() -> (utilization: Double?, inUseVRAMBytes: UInt64?) {
        guard let matching = IOServiceMatching("IOAccelerator") else { return (nil, nil) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }
        var maximum: Double?
        var maxVRAM: UInt64?
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
            for key in ["In use system memory", "vramUsedBytes"] {
                if let value = properties[key] as? NSNumber, value.uint64Value > 0 {
                    maxVRAM = max(maxVRAM ?? 0, value.uint64Value)
                }
            }
        }
        return (maximum.map { min(max($0, 0), 1) }, maxVRAM)
    }

    /// 系统实际功耗。PSTR 在两种供电状态下都等于真实系统负载（插电时充电功率只计入
    /// PDTR 总线值，不计入 PSTR——探针实测 PSTR≈遥测 SystemLoad）。不使用 PDTR 推导：
    /// 插拔瞬间 PDTR 残留旧值、电池电流滞后，任何减法都会产生瞬态错误数值。
    private func readPower(from properties: [String: Any]?) -> Double? {
        if let system = smc?.readNumber("PSTR"), system.isFinite, system > 0 { return system }
        if let properties {
            let telemetry = dictionary(in: properties, key: "PowerTelemetryData")
            if let load = milliwatts(in: telemetry, key: "SystemLoad") {
                return max(load, 0)
            }
        }
        return nil
    }

    private func readLoadAverage() -> (Double, Double, Double)? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return (loads[0], loads[1], loads[2])
    }

    private func readSystemUptime() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 {
            let boot = TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000
            return max(0, Date().timeIntervalSince1970 - boot)
        }
        return ProcessInfo.processInfo.systemUptime
    }

    private func formatThermalDetail(cpuTemp: Double?, gpuTemp: Double?, fans: [Int]) -> String {
        var parts: [String] = []
        if let cpuTemp {
            parts.append(String(format: "CPU %.0f°C", cpuTemp))
        }
        if let gpuTemp, abs(gpuTemp - (cpuTemp ?? -100)) >= 3 {
            parts.append(String(format: "GPU %.0f°C", gpuTemp))
        }
        if !fans.isEmpty {
            let active = fans.filter { $0 > 50 }
            if active.isEmpty {
                parts.append("风扇停转")
            } else {
                parts.append(active.map { "\($0)转" }.joined(separator: "/"))
            }
        } else if !parts.isEmpty {
            parts.append("被动散热")
        }
        return parts.isEmpty ? "不可用" : parts.joined(separator: " · ")
    }

    private func readNetworkUsage(currentTime: CFAbsoluteTime) -> (text: String, raw: String, compactDown: String, level: Double?, localIP: String?, primaryInterface: String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ("获取失败", "", "--", nil, nil, nil) }
        defer { freeifaddrs(ifaddr) }

        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var localIP: String?
        var primaryInterface: String?

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr!.pointee

            guard let namePtr = interface.ifa_name, let addrPtr = interface.ifa_addr else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("lo") { continue }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }

            let addrFamily = addrPtr.pointee.sa_family
            if addrFamily == UInt8(AF_LINK) {
                guard let data = interface.ifa_data else { continue }
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                inBytes += UInt64(networkData.ifi_ibytes)
                outBytes += UInt64(networkData.ifi_obytes)
            } else if addrFamily == UInt8(AF_INET), (flags & IFF_RUNNING) != 0 {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addrPtr,
                    socklen_t(addrPtr.pointee.sa_len),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let rawBytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    let ip = String(decoding: rawBytes, as: UTF8.self)
                    if !ip.hasPrefix("169.254."), !ip.hasPrefix("127.") {
                        if localIP == nil || name == "en0" {
                            localIP = ip
                            primaryInterface = name
                        }
                    }
                }
            }
        }

        let timeDelta = previousNetworkBytes.map { currentTime - $0.time } ?? 0
        let inDelta = previousNetworkBytes.map { inBytes >= $0.in ? inBytes - $0.in : 0 } ?? 0
        let outDelta = previousNetworkBytes.map { outBytes >= $0.out ? outBytes - $0.out : 0 } ?? 0

        previousNetworkBytes = (inBytes, outBytes, currentTime)

        guard timeDelta > 0 else { return ("计算中...", "", "0K/s", 0, localIP, primaryInterface) }

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
        func formatCompact(_ bytesPerSecond: Double) -> String {
            if bytesPerSecond >= 1024 * 1024 {
                return String(format: "%.1fM/s", bytesPerSecond / (1024 * 1024))
            } else if bytesPerSecond >= 1024 {
                return String(format: "%.0fK/s", bytesPerSecond / 1024)
            }
            return "0K/s"
        }

        let downText = formatSpeed(inSpeed)
        let upText = formatSpeed(outSpeed)
        let totalMBps = (inSpeed + outSpeed) / (1024 * 1024)
        let level = networkScaleWattsEquivalent.normalized(totalMBps * 10)
        return ("↓ \(downText)  ↑ \(upText)", "\(downText)/\(upText)", formatCompact(inSpeed + outSpeed), level, localIP, primaryInterface)
    }

    private func formatBatteryMetric(from powerFlow: PowerFlowSnapshot) -> (level: Double?, text: String, raw: String) {
        guard let level = powerFlow.batteryLevel, level.isFinite else {
            return (nil, "电池不可用", "")
        }
        let pct = Int((level * 100).rounded())
        var parts = ["\(pct)%"]
        if powerFlow.isCharging {
            if let fullMin = powerFlow.timeToFullMinutes, fullMin > 0 {
                parts.append("充剩 \(fullMin / 60)h\(fullMin % 60)m")
            } else {
                parts.append("充电中")
            }
        } else if powerFlow.externalConnected {
            parts.append(pct >= 99 ? "已充满" : "外接供电")
        } else if let emptyMin = powerFlow.timeToEmptyMinutes, emptyMin > 0 {
            parts.append("续航 \(emptyMin / 60)h\(emptyMin % 60)m")
        } else {
            parts.append("放电中")
        }
        if let health = powerFlow.batteryHealthPercent {
            parts.append("健康 \(health)%")
        }
        if let cycle = powerFlow.cycleCount {
            parts.append("循环 \(cycle)")
        }
        return (level, parts.joined(separator: " · "), "\(pct)%")
    }

    private func readPowerFlow(
        properties: [String: Any]?,
        cpu: Double?,
        gpu: Double?,
        cpuTemperature: Double?,
        fallbackWatts: Double?,
        nearbyDevices: [NearbyAppleDeviceBattery],
        wirelessPeripherals: [WirelessPeripheralBattery] = [],
        skipPackData: Bool = false
    ) -> PowerFlowSnapshot {
        guard let properties else {
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
                temperatureCelsius: smc?.readBatteryTemperature(),
                timeToFullMinutes: nil,
                cpuTemperatureCelsius: cpuTemperature,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                nearbyDevices: nearbyDevices,
                wirelessPeripherals: wirelessPeripherals,
                sampledAt: Date()
            )
        }

        let batteryLevel: Double?
        if let current = number(in: properties, key: "CurrentCapacity"),
           let maximum = number(in: properties, key: "MaxCapacity"),
           maximum > 0 {
            batteryLevel = maximum == 100
                ? min(max(current / 100, 0), 1)
                : min(max(current / maximum, 0), 1)
        } else {
            batteryLevel = nil
        }

        let batteryData = dictionary(in: properties, key: "BatteryData")
        let smcBatteryTemp = smc?.readBatteryTemperature()
        // 优先使用 SMC 微秒级电池热敏读数；仅在需要 DailyMaxSoc 或无 SMC 温度时按需读取 Pack。
        let packData = skipPackData ? [:] : smartBatteryPackData()
        let telemetry = dictionary(in: properties, key: "PowerTelemetryData")
        let distribution = dictionary(in: properties, key: "PowerDistribution")
        let adapter = dictionary(in: properties, key: "AdapterDetails")

        let isCharging = bool(in: properties, key: "IsCharging")
        let externalConnected = bool(in: properties, key: "ExternalConnected")
        let electricalBatteryWatts: Double? = {
            guard let amperage = number(in: properties, key: "Amperage"),
                  let voltage = number(in: properties, key: "Voltage") else { return nil }
            let watts = amperage * voltage / 1_000_000
            // 电池物理上不可能吞吐数百瓦；超限说明读到补码污染值，弃用。
            return (watts.isFinite && abs(watts) < 400) ? watts : nil
        }()

        // 系统负载：readPower 已统一返回 PSTR/遥测 SystemLoad（两种供电状态下都是
        // 真实负载，不含充电功率），直接采用。PDTR 是含充电的总线值且插拔瞬态会残留，
        // 不参与负载推导。
        let telemetrySystemWatts = milliwatts(in: telemetry, key: "SystemPowerIn")
        let telemetryLoadWatts = milliwatts(in: telemetry, key: "SystemLoad")
        let distributionInputWatts = milliwatts(in: distribution, key: "IPDInputPower")
        let systemWatts: Double? = fallbackWatts.flatMap { $0 > 0.05 ? $0 : nil }
            ?? telemetryLoadWatts
            ?? (externalConnected ? nil : telemetrySystemWatts)
        // 输入功率是适配器实际输出，充电时包含电池充电部分，与系统负载分开呈现。
        let inputWatts: Double?
        if externalConnected {
            if let input = telemetrySystemWatts ?? distributionInputWatts, input > 0.05 {
                inputWatts = input
            } else {
                inputWatts = systemWatts.map { $0 + max(electricalBatteryWatts ?? 0, 0) }
            }
        } else {
            inputWatts = systemWatts
        }
        let telemetryBatteryWatts = milliwatts(in: telemetry, key: "BatteryPower")
            ?? milliwatts(in: batteryData, key: "BatteryPower")
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

        let packTemperature = (number(in: packData, key: "Temperature")
            ?? number(in: batteryData, key: "Temperature")
            ?? number(in: properties, key: "Temperature")).flatMap { value -> Double? in
            let celsius = value > 1000 ? value / 100 : value / 10
            return (-20...100).contains(celsius) ? celsius : nil
        }
        let temperature = smcBatteryTemp ?? packTemperature

        func validMinutes(_ value: Double?) -> Int? {
            guard let value, value.isFinite, value > 0, value < 65_535 else { return nil }
            return Int(value.rounded())
        }
        let timeToFull = isCharging
            ? (validMinutes(number(in: properties, key: "AvgTimeToFull"))
                ?? validMinutes(number(in: properties, key: "TimeRemaining")))
            : nil
        let timeToEmpty = !externalConnected
            ? (validMinutes(number(in: properties, key: "AvgTimeToEmpty"))
                ?? validMinutes(number(in: batteryData, key: "AvgTimeToEmpty"))
                ?? validMinutes(number(in: properties, key: "TimeRemaining")))
            : nil

        let cycleCount = number(in: properties, key: "CycleCount").map { Int($0.rounded()) }
            ?? number(in: batteryData, key: "CycleCount").map { Int($0.rounded()) }
        let batteryHealthPercent: Int? = {
            guard let design = number(in: batteryData, key: "DesignCapacity") ?? number(in: properties, key: "DesignCapacity"),
                  design > 100,
                  let nominal = number(in: batteryData, key: "NominalChargeCapacity")
                      ?? number(in: batteryData, key: "AppleRawMaxCapacity")
                      ?? number(in: properties, key: "AppleRawMaxCapacity"),
                  nominal > 100 else { return nil }
            return min(100, max(10, Int(((nominal / design) * 100).rounded())))
        }()

        let adapterVoltageVolts = (number(in: adapter, key: "AdapterVoltage")
            ?? number(in: telemetry, key: "SystemVoltageIn")).flatMap { mv -> Double? in
            mv > 100 ? mv / 1_000 : (mv > 0 ? mv : nil)
        }
        let adapterCurrentAmps = (number(in: adapter, key: "Current")
            ?? number(in: telemetry, key: "SystemCurrentIn")).flatMap { ma -> Double? in
            ma > 0 ? ma / 1_000 : nil
        }
        let usbOutputWatts: Double? = {
            guard let ports = properties["PowerOutDetails"] as? [[String: Any]] else { return nil }
            let totalMilliwatts = ports.reduce(0.0) { acc, port in
                let mw = (port["FilteredPower"] as? NSNumber)?.doubleValue
                    ?? (port["PDPowermW"] as? NSNumber)?.doubleValue
                    ?? 0
                return acc + max(0, mw)
            }
            return totalMilliwatts >= 50 ? totalMilliwatts / 1_000 : nil
        }()

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
            timeToEmptyMinutes: timeToEmpty,
            batteryHealthPercent: batteryHealthPercent,
            cycleCount: cycleCount,
            adapterVoltageVolts: adapterVoltageVolts,
            adapterCurrentAmps: adapterCurrentAmps,
            usbOutputWatts: usbOutputWatts,
            cpuTemperatureCelsius: cpuTemperature,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            nearbyDevices: nearbyDevices,
            wirelessPeripherals: wirelessPeripherals,
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

    private func readMouseBattery(currentTime: CFAbsoluteTime) -> (level: Double?, text: String, raw: String) {
        if let cached = Self.sharedMouseBatteryCache.cachedValue(now: currentTime, successInterval: Self.mouseBatteryCacheInterval) {
            return cached
        }

        if let gHubBattery = gHubBatteryReader.read() {
            let charging = gHubBattery.isCharging ? " 充电中" : ""
            let value = (
                level: Double(gHubBattery.percent) / 100,
                text: "\(gHubBattery.percent)%\(charging) \(gHubBattery.name)",
                raw: "\(gHubBattery.percent)%"
            )
            Self.sharedMouseBatteryCache.store(value, failed: false, now: currentTime)
            return value
        }

        var candidates: [(name: String, percent: Int)] = []
        // 优先精准匹配 HID 事件与电源服务，避免全树遍历数千个内核注册表节点。
        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOHIDDevice", "IOPMPowerSource"] {
            guard let matching = IOServiceMatching(serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { continue }
            defer { IOObjectRelease(iterator) }
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
        Self.sharedMouseBatteryCache.store(value, failed: candidate == nil, now: currentTime)
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
        return ["mouse", "trackball", "trackpad", "mx master", "mx anywhere", "deathadder", "viper", "basilisk", "g pro", "superlight", "鼠标", "触控板"].contains {
            name.contains($0)
        }
    }
}

private final class SharedMouseBatteryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (level: Double?, text: String, raw: String)?
    private var failed = false
    private var sampledAt: CFAbsoluteTime = 0

    func cachedValue(now: CFAbsoluteTime, successInterval: TimeInterval) -> (level: Double?, text: String, raw: String)? {
        lock.lock()
        defer { lock.unlock() }
        let retryInterval: TimeInterval = failed ? 60 * 60 : successInterval
        guard let cached, now - sampledAt < retryInterval else { return nil }
        return cached
    }

    func store(_ value: (level: Double?, text: String, raw: String), failed: Bool, now: CFAbsoluteTime) {
        lock.lock()
        self.cached = value
        self.failed = failed
        self.sampledAt = now
        lock.unlock()
    }
}

private final class NearbyRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [NearbyAppleDeviceBattery] = []

    func store(_ value: [NearbyAppleDeviceBattery]) {
        lock.lock()
        devices = value
        lock.unlock()
    }

    func load() -> [NearbyAppleDeviceBattery] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }
}

private final class AppleSMC: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: (size: Int, type: String)] = [:]
    private var missingKeys: Set<UInt32> = []

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
        let encodedKey = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }

        lock.lock()
        defer { lock.unlock() }
        if missingKeys.contains(encodedKey) { return nil }

        let keyMeta: (size: Int, type: String)
        if let cached = keyInfoCache[encodedKey] {
            keyMeta = cached
        } else {
            var infoInput = SMCKeyData()
            var infoOutput = SMCKeyData()
            infoInput.key = encodedKey
            infoInput.data8 = 9
            guard call(&infoInput, &infoOutput) == kIOReturnSuccess else {
                missingKeys.insert(encodedKey)
                return nil
            }
            let size = Int(infoOutput.keyInfo.dataSize)
            let type = infoOutput.keyInfo.dataType.smcString
            guard size > 0, size <= 32 else {
                missingKeys.insert(encodedKey)
                return nil
            }
            keyMeta = (size, type)
            keyInfoCache[encodedKey] = keyMeta
        }

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = encodedKey
        input.keyInfo.dataSize = IOByteCount32(keyMeta.size)
        input.data8 = 5
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(keyMeta.size)) }
        return decode(type: keyMeta.type, bytes: bytes)
    }

    func readBatteryTemperature() -> Double? {
        for key in ["TB0T", "TB1T", "TB2T"] {
            if let val = readNumber(key), val.isFinite, (0...85).contains(val) {
                return val
            }
        }
        return nil
    }

    func readCPUTemperature() -> Double? {
        var best: Double?
        for key in ["Tp0T", "Tp09", "Tp05", "Tp01", "Tc0p", "TC0P"] {
            if let val = readNumber(key), val.isFinite, (15...120).contains(val) {
                best = max(best ?? val, val)
            }
        }
        return best
    }

    func readGPUTemperature() -> Double? {
        var best: Double?
        for key in ["Tg05", "Tg0D", "Tg0P", "TG0P"] {
            if let val = readNumber(key), val.isFinite, (15...120).contains(val) {
                best = max(best ?? val, val)
            }
        }
        return best
    }

    func readFanSpeeds() -> [Int] {
        guard let countVal = readNumber("FNum"), countVal >= 1 else { return [] }
        let count = min(Int(countVal.rounded()), 4)
        var speeds: [Int] = []
        for index in 0..<count {
            if let rpm = readNumber("F\(index)Ac"), rpm.isFinite, rpm >= 0, rpm < 12_000 {
                speeds.append(Int(rpm.rounded()))
            }
        }
        return speeds
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
