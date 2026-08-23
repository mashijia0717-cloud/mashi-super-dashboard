import Foundation

/// 可显示在菜单栏图标右侧的纯数字指标。
/// 数字之间不带名称，便于在菜单栏保持紧凑的原生样式。
enum MenuBarNumberOption: String, CaseIterable, Sendable {
    case battery
    case power
    case mouseBattery

    static let defaultsKey = "menuBarDisplayedNumbers"

    var title: String {
        switch self {
        case .battery: "Mac 电量"
        case .power: "实际功率"
        case .mouseBattery: "鼠标电量"
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
