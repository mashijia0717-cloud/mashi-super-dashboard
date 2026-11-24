import Foundation
import UserNotifications

final class DashboardNotificationManager: @unchecked Sendable {
    static let shared = DashboardNotificationManager()

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private let lock = NSLock()
    private var lastBatteryWarningDate: Date?
    private var lastThermalWarningDate: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dashboardNotificationsEnabled")
    }

    func authorizationDescription(completion: @escaping @Sendable (String) -> Void) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            completion("调试构建无法申请系统通知权限，请从正式 App 运行。")
            return
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: completion("系统已允许通知。")
            case .denied: completion("系统未允许通知，请在系统设置 → 通知中允许本应用。")
            case .notDetermined: completion("尚未授权，开启并保存后将请求系统权限。")
            @unknown default: completion("无法识别系统通知权限状态。")
            }
        }
    }

    func requestAuthorizationIfNeeded(completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        guard isEnabled else { completion(nil); return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            completion("通知权限需要从正式 App 应用包中申请。")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            completion(error?.localizedDescription ?? (granted ? nil : "系统未允许通知，请在系统设置 → 通知中允许本应用。"))
        }
    }

    func evaluatePower(_ snapshot: PowerFlowSnapshot) {
        guard isEnabled else { return }
        let batteryHot = snapshot.temperatureCelsius.map { $0 >= 42 } ?? false
        let cpuHot = snapshot.cpuTemperatureCelsius.map { $0 >= 95 } ?? false
        let temperatureWarning = batteryHot || cpuHot
        let batteryWarning =
            !snapshot.externalConnected && (snapshot.batteryLevel ?? 1) <= 0.15
        guard temperatureWarning || batteryWarning else { return }

        let now = Date()
        var sendThermal = false
        var sendBattery = false
        lock.lock()
        if temperatureWarning, (lastThermalWarningDate.map { now.timeIntervalSince($0) > 30 * 60 } ?? true) {
            lastThermalWarningDate = now
            sendThermal = true
        }
        if batteryWarning, (lastBatteryWarningDate.map { now.timeIntervalSince($0) > 30 * 60 } ?? true) {
            lastBatteryWarningDate = now
            sendBattery = true
        }
        lock.unlock()

        if sendThermal {
            if batteryHot {
                notify(
                    title: "Mac 电池温度偏高",
                    body: String(
                        format: "当前电池温度 %.1f°C，请留意散热与高负载应用。",
                        snapshot.temperatureCelsius ?? 0
                    )
                )
            } else if cpuHot {
                notify(
                    title: "Mac 处理器温度偏高",
                    body: String(
                        format: "当前 CPU 温度 %.1f°C，建议检查高能耗进程。",
                        snapshot.cpuTemperatureCelsius ?? 0
                    )
                )
            }
        }
        if sendBattery {
            notify(
                title: "Mac 电量较低",
                body: "当前仅剩 \(Int(((snapshot.batteryLevel ?? 0) * 100).rounded()))%，请连接电源。"
            )
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
