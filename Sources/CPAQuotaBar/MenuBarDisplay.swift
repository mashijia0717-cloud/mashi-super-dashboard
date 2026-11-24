import Foundation

enum MenuBarLineOption: String, CaseIterable, Sendable {
    case cpu, gpu, memory, battery, power, mouseBattery, cpuTemp, disk

    static let defaultsKey = "menuBarDisplayedLines"
    static let defaultSelection: [Self] = [.cpu, .gpu, .memory]

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .battery: "Mac 电量"
        case .power: "实际功率"
        case .mouseBattery: "鼠标电量"
        case .cpuTemp: "CPU 温度"
        case .disk: "磁盘空间"
        }
    }

    var isBattery: Bool { self == .battery || self == .mouseBattery }
    var requiresPowerSample: Bool { isBattery || self == .power }
    var requiresThermalSample: Bool { self == .cpuTemp }
    var requiresDiskSample: Bool { self == .disk }

    static func savedSelection(from defaults: UserDefaults = .standard) -> [Self] {
        let values = defaults.stringArray(forKey: defaultsKey) ?? []
        return defaultSelection.enumerated().map { index, fallback in
            index < values.count ? (Self(rawValue: values[index]) ?? fallback) : fallback
        }
    }

    static func saveSelection(_ selection: [Self], to defaults: UserDefaults = .standard) {
        guard selection.count == 3 else { return }
        defaults.set(selection.map(\.rawValue), forKey: defaultsKey)
    }
}

/// 可显示在菜单栏图标右侧的纯数字指标。
/// 数字之间不带名称，便于在菜单栏保持紧凑的原生样式。
enum MenuBarNumberOption: String, CaseIterable, Sendable {
    case cpu
    case memory
    case cpuTemp
    case network
    case battery
    case power
    case mouseBattery

    static let defaultsKey = "menuBarDisplayedNumbers"

    var title: String {
        switch self {
        case .cpu: "CPU 占用"
        case .memory: "内存占用"
        case .cpuTemp: "CPU 温度"
        case .network: "实时网速"
        case .battery: "Mac 电量"
        case .power: "实际功率"
        case .mouseBattery: "鼠标电量"
        }
    }

    var requiresPowerSample: Bool {
        switch self {
        case .battery, .power, .mouseBattery: true
        case .cpu, .memory, .cpuTemp, .network: false
        }
    }

    /// 新安装默认不占用菜单栏；老版本的菜单栏模式会自动迁移为等价的 Codex 数字。
    static func savedSelection(from defaults: UserDefaults = .standard) -> Set<Self> {
        if let values = defaults.stringArray(forKey: defaultsKey) {
            return Set(values.compactMap(Self.init))
        }

        return []
    }

    static func saveSelection(
        _ selection: Set<Self>,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(
            allCases.filter(selection.contains).map(\.rawValue),
            forKey: defaultsKey
        )
    }
}

/// 菜单栏后台采样周期：默认 2 秒兼顾实时感与极低功耗，用户可按需调节。
enum MenuBarRefreshInterval: Int, CaseIterable, Sendable {
    case fast = 1
    case balanced = 2
    case powerSaving = 3
    case relaxed = 5

    static let defaultsKey = "menuBarRefreshIntervalSeconds"
    static let defaultInterval: Self = .balanced

    var title: String {
        switch self {
        case .fast: "1 秒（高实时）"
        case .balanced: "2 秒（均衡推荐）"
        case .powerSaving: "3 秒（省电轻量）"
        case .relaxed: "5 秒（极简待机）"
        }
    }

    var seconds: Int { rawValue }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let raw = defaults.integer(forKey: defaultsKey)
        return Self(rawValue: raw) ?? defaultInterval
    }

    static func save(_ value: Self, to defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
    }
}
