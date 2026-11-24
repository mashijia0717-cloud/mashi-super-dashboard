import Foundation

enum AmbientBrightnessCurve {
    static func target(lux: Double) -> Int? {
        guard lux.isFinite, lux >= 0, lux <= 1_000_000 else { return nil }
        return Int((18 + 70 * log1p(min(lux, 800)) / log1p(800)).rounded())
    }

    static func parseLux(_ output: String) -> Double? {
        let pattern = #""CurrentLux"\s*=\s*(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }
}

@MainActor
final class AutoBrightnessController {
    static let shared = AutoBrightnessController()
    private nonisolated static let preferenceKey = "superDashboardAutoBrightnessEnabled"
    private var samplingTask: Task<Void, Never>?
    private var sleeping = false
    private(set) var status = "自动亮度未开启"

    var isEnabled: Bool { Self.preferenceEnabled }

    nonisolated static var preferenceEnabled: Bool {
        let pauseFile = DisplayConsolePaths.alsStateDir + "paused_until"
        let pausedUntil = Double((try? String(contentsOfFile: pauseFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        guard pausedUntil <= Date().timeIntervalSince1970 else { return false }
        if UserDefaults.standard.object(forKey: Self.preferenceKey) != nil {
            return UserDefaults.standard.bool(forKey: Self.preferenceKey)
        }
        return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.mashijia.als-auto-brightness.plist")
    }

    func setEnabled(_ enabled: Bool) async -> String {
        let previous = samplingTask
        stop()
        do {
            try FileManager.default.createDirectory(atPath: DisplayConsolePaths.alsStateDir, withIntermediateDirectories: true)
            try (enabled ? "0" : "4102444800").write(toFile: DisplayConsolePaths.alsStateDir + "paused_until", atomically: true, encoding: .utf8)
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        } catch {
            status = "无法保存自动亮度设置：\(error.localizedDescription)"
            return status
        }
        await previous?.value
        guard enabled else {
            status = "已切换为手动固定亮度"
            return status
        }
        status = await Task.detached(priority: .utility) { Self.sample(force: true) }.value
        sync()
        return status
    }

    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { stop() } else { sync() }
    }

    func sync(deferFirstSample: Bool = false) {
        guard isEnabled, !sleeping else { stop(); return }
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            if deferFirstSample {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
            }
            while !Task.isCancelled {
                guard self?.isEnabled == true else { break }
                let message = await Task.detached(priority: .utility) { Self.sample(force: false) }.value
                guard !Task.isCancelled else { return }
                self?.status = message
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
            }
            self?.samplingTask = nil
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    nonisolated private static func sample(force: Bool) -> String {
        guard DisplaySafetyPolicy.usableExternalCount > 0 else { return "外接屏不可用，暂停自动亮度" }
        guard !DisplayConsolePaths.screensPoweredOff(), DisplayConsolePaths.anyDisplayAwake() else {
            return "屏幕休眠期间暂停自动亮度"
        }
        guard let helper = DisplayConsolePaths.helperPath("DDCControl") else { return "缺少显示器亮度组件" }
        let sensor = DisplayConsolePaths.runCommand("/usr/sbin/ioreg", ["-r", "-k", "CurrentLux"], timeout: 3)
        guard sensor.code == 0, let lux = AmbientBrightnessCurve.parseLux(sensor.output),
              let target = AmbientBrightnessCurve.target(lux: lux) else {
            return "自动亮度已开启，当前未读到有效环境光传感器"
        }
        let lastFile = DisplayConsolePaths.alsStateDir + "last_target"
        if !force, let previous = try? String(contentsOfFile: lastFile, encoding: .utf8),
           let last = Int(previous.trimmingCharacters(in: .whitespacesAndNewlines)), abs(last - target) < 6 {
            return "环境光 \(Int(lux)) lux · 保持 \(last)%"
        }
        guard !DisplayConsolePaths.screensPoweredOff(), DisplayConsolePaths.anyDisplayAwake() else {
            return "屏幕休眠期间暂停自动亮度"
        }
        let pausedUntil = Double((try? String(contentsOfFile: DisplayConsolePaths.alsStateDir + "paused_until", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        guard pausedUntil <= Date().timeIntervalSince1970 else { return "自动亮度已暂停" }
        guard DisplaySafetyPolicy.usableExternalCount > 0 else { return "外接屏已断开，取消延迟亮度任务" }
        let verified = DisplayConsolePaths.withBrightnessAccess {
            guard preferenceEnabled, DisplaySafetyPolicy.usableExternalCount > 0 else { return false }
            let result = DisplayConsolePaths.runCommand(helper, ["set", "0x10", String(target)], timeout: 3)
            return result.succeeded && result.json?["verified"] as? Bool == true
        }
        guard verified else { return "外接屏未确认自动亮度" }
        do {
            try FileManager.default.createDirectory(atPath: DisplayConsolePaths.alsStateDir, withIntermediateDirectories: true)
            try String(target).write(toFile: lastFile, atomically: true, encoding: .utf8)
        } catch {
            return "已调至 \(target)%，无法保存亮度记录"
        }
        return "环境光 \(Int(lux)) lux · 已调至 \(target)%"
    }
}
