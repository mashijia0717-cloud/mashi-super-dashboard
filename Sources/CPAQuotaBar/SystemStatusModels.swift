import Foundation

struct SystemMetric: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case cpu, gpu, memory, disk, power, network, battery, mouseBattery
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

struct SystemStatusSnapshot: Sendable, Equatable {
    let metrics: [SystemMetric]
    let powerFlow: PowerFlowSnapshot
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
    let lowPowerMode: Bool
    let nearbyDevices: [NearbyAppleDeviceBattery]
    let sampledAt: Date

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
