import Foundation

struct SystemMetric: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case cpu, gpu, memory, disk, power, thermal, network, battery, mouseBattery
    }

    let kind: Kind
    let title: String
    let detail: String
    let value: Double?
    let rawString: String?
    let accessibilityHelp: String

    var id: String { kind.rawValue }
    var clampedValue: Double? { value.map { min(max($0, 0), 1) } }

    init(kind: Kind, title: String, detail: String, value: Double?, rawString: String? = nil, accessibilityHelp: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.value = value
        self.rawString = rawString
        self.accessibilityHelp = accessibilityHelp
    }
}

struct SystemOverviewSummary: Sendable, Equatable {
    let uptimeSeconds: TimeInterval
    let loadAverage1m: Double?
    let loadAverage5m: Double?
    let localIPAddress: String?
    let interfaceName: String?
    let memoryPressure: String
    let cpuTemperatureCelsius: Double?
    let gpuTemperatureCelsius: Double?
    let fanSpeedsRPM: [Int]

    static let empty = Self(
        uptimeSeconds: 0,
        loadAverage1m: nil,
        loadAverage5m: nil,
        localIPAddress: nil,
        interfaceName: nil,
        memoryPressure: "正常",
        cpuTemperatureCelsius: nil,
        gpuTemperatureCelsius: nil,
        fanSpeedsRPM: []
    )
}

struct SystemStatusSnapshot: Sendable, Equatable {
    let metrics: [SystemMetric]
    let powerFlow: PowerFlowSnapshot
    let summary: SystemOverviewSummary

    init(
        metrics: [SystemMetric],
        powerFlow: PowerFlowSnapshot,
        summary: SystemOverviewSummary = .empty
    ) {
        self.metrics = metrics
        self.powerFlow = powerFlow
        self.summary = summary
    }
}

/// 物理内存与虚拟内存的四维深度透视快照（供“内存清理”页面直观展示与前后对比）。
struct MemoryCompositionSnapshot: Sendable, Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let availableBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let uncompressedInCompressorBytes: UInt64
    let cachedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let swapInsPerSecond: Double
    let swapOutsPerSecond: Double
    let pageInsTotal: UInt64
    let pageOutsTotal: UInt64
    let pressureLevel: Int
    let pressureLabel: String
    let sampledAt: Date

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var compressionSavedBytes: UInt64 {
        uncompressedInCompressorBytes > compressedBytes ? (uncompressedInCompressorBytes - compressedBytes) : 0
    }

    var isSwapActive: Bool {
        swapPagesPerSecond > 0
    }

    var swapPagesPerSecond: Double {
        [swapInsPerSecond, swapOutsPerSecond].reduce(0) { total, rate in
            total + (rate.isFinite ? max(0, rate) : 0)
        }
    }

    var physicalCompositionFractions: [Double] {
        guard totalBytes > 0 else { return [0, 0, 0, 0] }
        var remaining = totalBytes
        return [appBytes, wiredBytes, compressedBytes, cachedBytes].map { bytes in
            let displayedBytes = min(bytes, remaining)
            remaining -= displayedBytes
            return Double(displayedBytes) / Double(totalBytes)
        }
    }
}

struct MemoryCleanupComparison: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case increased(UInt64)
        case decreased(UInt64)
        case unchanged
        case unavailable
    }

    let beforeAvailable: UInt64?
    let afterAvailable: UInt64?
    let confirmedTerminationCount: Int
    let requestedTerminationCount: Int?

    var change: Change {
        guard let beforeAvailable, let afterAvailable else { return .unavailable }
        if afterAvailable > beforeAvailable {
            return .increased(afterAvailable - beforeAvailable)
        }
        if afterAvailable < beforeAvailable {
            return .decreased(beforeAvailable - afterAvailable)
        }
        return .unchanged
    }

    var message: String {
        let summary: String
        if let beforeAvailable, let afterAvailable {
            let values = "可用 \(Self.formatBytes(beforeAvailable)) → \(Self.formatBytes(afterAvailable))"
            switch change {
            case .increased(let bytes):
                summary = "\(values) · 增加 \(Self.formatBytes(bytes))"
            case .decreased(let bytes):
                summary = "\(values) · 减少 \(Self.formatBytes(bytes))"
            default:
                summary = "\(values) · 暂无变化"
            }
        } else {
            summary = "内存采样不完整，暂无法比较整理前后变化"
        }
        let confirmed = max(0, confirmedTerminationCount)
        let request: String
        if let requested = requestedTerminationCount, requested > confirmed {
            request = "已确认退出 \(confirmed)/\(requested) 个应用；其余可能待保存或尚未确认。"
        } else if confirmed > 0 {
            request = "已确认退出 \(confirmed) 个应用。"
        } else if requestedTerminationCount == 0 {
            request = "仅整理仪表盘自身缓存与空闲分配。"
        } else {
            request = "暂未确认有应用退出。"
        }
        return "\(summary)\n\(request)系统内存也会随其他应用活动波动。"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

enum NearbyAppleDeviceKind: String, CaseIterable, Sendable {
    case iPhone
    case iPad
    case appleWatch

    var displayName: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleWatch: "Apple Watch"
        }
    }

    var symbolName: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleWatch: "applewatch"
        }
    }
}

struct NearbyAppleDeviceBattery: Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case scanning
        case available
        case pairingRequired
        case notFound
    }

    let kind: NearbyAppleDeviceKind
    let name: String
    let level: Double?
    let isCharging: Bool
    let availability: Availability
    let lastUpdated: Date?

    static func placeholder(for kind: NearbyAppleDeviceKind) -> Self {
        Self(
            kind: kind,
            name: kind.displayName,
            level: nil,
            isCharging: false,
            availability: .scanning,
            lastUpdated: nil
        )
    }

    static var placeholders: [Self] {
        NearbyAppleDeviceKind.allCases.map(Self.placeholder)
    }
}

struct PowerFlowSnapshot: Sendable, Equatable {
    let batteryLevel: Double?
    let isCharging: Bool
    let externalConnected: Bool
    let chargeLimitPercent: Int?
    let adapterWatts: Double?
    let inputWatts: Double?
    let systemWatts: Double?
    let batteryWatts: Double?
    let cpuWatts: Double?
    let gpuWatts: Double?
    let otherWatts: Double?
    let temperatureCelsius: Double?
    let timeToFullMinutes: Int?
    let timeToEmptyMinutes: Int?
    let batteryHealthPercent: Int?
    let cycleCount: Int?
    let adapterVoltageVolts: Double?
    let adapterCurrentAmps: Double?
    let usbOutputWatts: Double?
    let cpuTemperatureCelsius: Double?
    let lowPowerMode: Bool
    let nearbyDevices: [NearbyAppleDeviceBattery]
    let wirelessPeripherals: [WirelessPeripheralBattery]
    let sampledAt: Date

    init(
        batteryLevel: Double?,
        isCharging: Bool,
        externalConnected: Bool,
        chargeLimitPercent: Int?,
        adapterWatts: Double?,
        inputWatts: Double?,
        systemWatts: Double?,
        batteryWatts: Double?,
        cpuWatts: Double?,
        gpuWatts: Double?,
        otherWatts: Double?,
        temperatureCelsius: Double?,
        timeToFullMinutes: Int?,
        timeToEmptyMinutes: Int? = nil,
        batteryHealthPercent: Int? = nil,
        cycleCount: Int? = nil,
        adapterVoltageVolts: Double? = nil,
        adapterCurrentAmps: Double? = nil,
        usbOutputWatts: Double? = nil,
        cpuTemperatureCelsius: Double? = nil,
        lowPowerMode: Bool,
        nearbyDevices: [NearbyAppleDeviceBattery],
        wirelessPeripherals: [WirelessPeripheralBattery] = [],
        sampledAt: Date
    ) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.chargeLimitPercent = chargeLimitPercent
        self.adapterWatts = adapterWatts
        self.inputWatts = inputWatts
        self.systemWatts = systemWatts
        self.batteryWatts = batteryWatts
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.otherWatts = otherWatts
        self.temperatureCelsius = temperatureCelsius
        self.timeToFullMinutes = timeToFullMinutes
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.batteryHealthPercent = batteryHealthPercent
        self.cycleCount = cycleCount
        self.adapterVoltageVolts = adapterVoltageVolts
        self.adapterCurrentAmps = adapterCurrentAmps
        self.usbOutputWatts = usbOutputWatts
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.lowPowerMode = lowPowerMode
        self.nearbyDevices = nearbyDevices
        self.wirelessPeripherals = wirelessPeripherals
        self.sampledAt = sampledAt
    }

    static let placeholder = PowerFlowSnapshot(
        batteryLevel: nil,
        isCharging: false,
        externalConnected: false,
        chargeLimitPercent: nil,
        adapterWatts: nil,
        inputWatts: nil,
        systemWatts: nil,
        batteryWatts: nil,
        cpuWatts: nil,
        gpuWatts: nil,
        otherWatts: nil,
        temperatureCelsius: nil,
        timeToFullMinutes: nil,
        lowPowerMode: false,
        nearbyDevices: NearbyAppleDeviceBattery.placeholders,
        sampledAt: Date()
    )
}

enum PowerSupplyMode: Sendable, Equatable {
    /// 未接适配器，电池直接向右侧负载供电。
    case batteryOnly
    /// 适配器给系统供电，电池不充不放。
    case adapterDirect
    /// 适配器同时给系统供电并给电池充电。
    case adapterCharging
    /// 适配器功率不足或瞬时高负载，适配器与电池共同给系统供电。
    case adapterWithBatteryAssist
}

/// 把底层电池正负功率和连接状态归一化为唯一的供电拓扑。
/// 界面文案、节点状态与动画必须共同读取这里，避免各自判断后出现互相矛盾。
struct PowerFlowRouting: Sendable, Equatable {
    let mode: PowerSupplyMode
    let systemLoadWatts: Double
    let adapterToSystemWatts: Double
    let adapterToBatteryWatts: Double
    let batteryToSystemWatts: Double
    let batteryToLoadsWatts: Double

    init(snapshot: PowerFlowSnapshot) {
        let componentLoad = [snapshot.cpuWatts, snapshot.gpuWatts, snapshot.otherWatts]
            .compactMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0, +)
        let systemLoad = snapshot.systemWatts.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        } ?? componentLoad
        let signedBattery = snapshot.batteryWatts.flatMap {
            $0.isFinite ? $0 : nil
        }
        let measuredBattery = abs(signedBattery ?? 0)

        let resolvedMode: PowerSupplyMode
        if !snapshot.externalConnected {
            resolvedMode = .batteryOnly
        } else if snapshot.isCharging {
            resolvedMode = .adapterCharging
        } else if (signedBattery ?? 0) < -0.05 {
            resolvedMode = .adapterWithBatteryAssist
        } else {
            resolvedMode = .adapterDirect
        }

        mode = resolvedMode
        systemLoadWatts = max(systemLoad, 0)
        switch resolvedMode {
        case .batteryOnly:
            adapterToSystemWatts = 0
            adapterToBatteryWatts = 0
            batteryToSystemWatts = 0
            batteryToLoadsWatts = measuredBattery >= 0.05 ? measuredBattery : max(systemLoad, 0)
        case .adapterDirect:
            adapterToSystemWatts = max(systemLoad, 0)
            adapterToBatteryWatts = 0
            batteryToSystemWatts = 0
            batteryToLoadsWatts = 0
        case .adapterCharging:
            adapterToSystemWatts = max(systemLoad, 0)
            adapterToBatteryWatts = measuredBattery
            batteryToSystemWatts = 0
            batteryToLoadsWatts = 0
        case .adapterWithBatteryAssist:
            let batteryAssist = min(measuredBattery, max(systemLoad, 0))
            adapterToSystemWatts = max(systemLoad - batteryAssist, 0)
            adapterToBatteryWatts = 0
            batteryToSystemWatts = batteryAssist
            batteryToLoadsWatts = 0
        }
    }

    var adapterOutputWatts: Double {
        adapterToSystemWatts + adapterToBatteryWatts
    }

    var title: String {
        switch mode {
        case .batteryOnly: return "电池供电"
        case .adapterDirect: return "适配器直供"
        case .adapterCharging: return "供电 + 充电"
        case .adapterWithBatteryAssist: return "混合供电"
        }
    }
}

struct PowerScale: Sendable {
    private(set) var maximumWatts: Double = 50

    mutating func normalized(_ watts: Double) -> Double {
        if watts > maximumWatts {
            maximumWatts = watts * 1.25
        } else {
            maximumWatts = max(50, maximumWatts * 0.96)
        }
        return min(max(watts / maximumWatts, 0), 1)
    }
}
