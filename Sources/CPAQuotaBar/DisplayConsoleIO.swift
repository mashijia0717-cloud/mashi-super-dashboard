import AppKit
import Foundation

enum ScreenPageLayout: String, CaseIterable, Sendable {
    case external = "外接专注"
    case extended = "双屏扩展"
    case mirrored = "双屏镜像"

    var title: String {
        switch self {
        case .external: "仅外屏"
        case .extended: "扩展"
        case .mirrored: "镜像"
        }
    }
}

enum ScreenBlankState: Sendable {
    case idle, active, pendingRestore, unknown
    var needsRelease: Bool { self == .active || self == .pendingRestore }
}

struct ScreenLayoutTrial: Equatable, Sendable {
    let token: String
    let expires: Date

    init?(_ json: [String: Any]?, key: String) {
        guard let token = json?[key] as? String, !token.isEmpty,
              let seconds = json?["expires"] as? Double, seconds.isFinite else { return nil }
        self.token = token
        expires = Date(timeIntervalSince1970: seconds)
    }
}

struct DisplayConsoleSnapshot: Sendable {
    var screens: [DisplayScreenItem] = []
    var savedLayout: String?
    var failure: String?
    var externalBrightness: Int?
    var builtinBrightness: Int?
    var blank: ScreenBlankState = .unknown
    var trial: ScreenLayoutTrial?
    var lidOpen = false
    var mayRecoverBuiltin = false

    var online: [DisplayScreenItem] { screens.filter(\.isOnline) }
    var physicalOnline: [DisplayScreenItem] { online.filter { $0.virtual != true } }
    var aoc: DisplayScreenItem? { online.first(where: \.isAOC) }
    var builtin: DisplayScreenItem? { online.first(where: \.builtin) }
    var knownScreens: Bool { online.allSatisfy { $0.builtin || $0.isAOC } }
    var canEdit: Bool { failure == nil && blank == .idle && trial == nil }
    var canBlank: Bool { canEdit && lidOpen && knownScreens && online.contains(where: \.isReady) && (aoc?.isReady ?? true) }
    var liveLayout: ScreenPageLayout? {
        guard aoc != nil, knownScreens else { return nil }
        if online.contains(where: \.mirror) { return .mirrored }
        return builtin == nil ? .external : .extended
    }

    func canApply(_ layout: ScreenPageLayout) -> Bool {
        guard canEdit, knownScreens, let aoc, aoc.isReady else { return false }
        return layout == .external || (lidOpen && screens.contains(where: \.builtin))
    }
}

struct DisplayConsoleIO: Sendable {
    var helperPath: @Sendable (String) -> String? = DisplayConsolePaths.helperPath
    var run: @Sendable (String, [String], TimeInterval) -> DisplayConsolePaths.ExecResult = DisplayConsolePaths.runCommand
    var lidOpen: @Sendable () -> Bool = { DisplaySafetyPolicy.lidIsOpen }
    var connected: @MainActor @Sendable () -> [ConnectedDisplay] = { ConnectedDisplays.current() }
    var readBuiltin: @Sendable () -> Double? = BuiltinBrightnessBridge.readPercent
    var writeBuiltin: @Sendable (Double) -> Bool = BuiltinBrightnessBridge.setPercent
    var brightnessAccess: @Sendable (@Sendable () -> Bool) -> Bool = { DisplayConsolePaths.withBrightnessAccess($0) }
    var autoEnabled: @Sendable () -> Bool = { AutoBrightnessController.preferenceEnabled }
    var setAuto: @MainActor @Sendable (Bool) async -> String = { await AutoBrightnessController.shared.setEnabled($0) }
    var openSettings: @MainActor @Sendable () -> Bool = {
        URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension").map { NSWorkspace.shared.open($0) } ?? false
    }
    var startBlank: @MainActor @Sendable (String, @escaping @Sendable (Int32) -> Void) throws -> Void = { path, finished in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished($0.terminationStatus) }
        try process.run()
    }

    func command(_ helper: String, _ arguments: [String], timeout: TimeInterval = 5) -> DisplayConsolePaths.ExecResult {
        guard let path = helperPath(helper) else { return .init(code: -1, output: "缺少 \(helper) 组件") }
        return run(path, arguments, timeout)
    }

    func blankState() -> ScreenBlankState {
        let reply = command("ScreenBlank", ["--status"])
        guard reply.code == 0, let data = reply.json, let active = data["active"] as? Bool,
              let pending = data["pendingRestore"] as? Bool else { return .unknown }
        if active { return .active }
        return pending ? .pendingRestore : .idle
    }

    func snapshot(readBrightness: Bool = true) -> DisplayConsoleSnapshot {
        var result = DisplayConsoleSnapshot()
        result.blank = blankState()
        result.lidOpen = lidOpen()
        let reply = command("DisplayManager", ["status"])
        guard reply.succeeded, let json = reply.json, let rows = json["screens"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let screens = try? JSONDecoder().decode([DisplayScreenItem].self, from: data) else {
            result.failure = "读取显示器失败：\(reply.failure)"
            return result
        }
        result.screens = screens
        result.savedLayout = json["preset"] as? String
        result.trial = ScreenLayoutTrial(json, key: "pendingToken")
        if json["pendingToken"] != nil && result.trial == nil { result.failure = "布局确认记录暂时无法读取" }
        guard result.blank == .idle else { return result }
        if !result.physicalOnline.contains(where: { !$0.builtin }) && result.canEdit && result.lidOpen {
            let check = command("DisplayManager", ["--check-recovery"])
            result.mayRecoverBuiltin = check.succeeded && check.json?["decision"] as? String == "restore-owned"
        }
        guard readBrightness else { return result }
        if result.aoc?.isReady == true {
            let reply = command("DDCControl", ["get", "0x10"], timeout: 3)
            if reply.succeeded, let value = reply.json?["current"] as? Int, (0...100).contains(value) {
                result.externalBrightness = value
            }
        }
        if result.builtin?.isReady == true, let value = readBuiltin(), value.isFinite, (0...100).contains(value) {
            result.builtinBrightness = Int(value.rounded())
        }
        return result
    }

    func setBrightness(_ value: Int, on target: DisplayScreenItem) -> Bool {
        brightnessAccess {
            let live = snapshot(readBrightness: false)
            guard live.canEdit, live.screens.contains(where: {
                $0.id == target.id && $0.serial == target.serial && $0.builtin == target.builtin && $0.isReady
            }) else { return false }
            if target.builtin {
                guard (2...100).contains(value), writeBuiltin(Double(value)), let actual = readBuiltin() else { return false }
                return abs(actual - Double(value)) <= 2
            }
            guard target.isAOC, (0...100).contains(value), !autoEnabled() else { return false }
            let reply = command("DDCControl", ["set", "0x10", String(value)], timeout: 3)
            return reply.succeeded && reply.json?["verified"] as? Bool == true
        }
    }
}

extension DisplayConsolePaths.ExecResult {
    var json: [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    }

    var succeeded: Bool { code == 0 && json?["ok"] as? Bool == true }
    var failure: String { json?["error"] as? String ?? (output.isEmpty ? "组件未返回结果" : String(output.prefix(120))) }
}
