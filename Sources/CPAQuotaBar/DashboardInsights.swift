import Foundation
import UserNotifications

final class DashboardNotificationManager: @unchecked Sendable {
    static let shared = DashboardNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var lastBatteryWarningDate: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dashboardNotificationsEnabled")
    }

    func requestAuthorizationIfNeeded() {
        guard isEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluatePower(_ snapshot: PowerFlowSnapshot) {
        guard isEnabled else { return }
        let temperatureWarning = snapshot.temperatureCelsius.map { $0 >= 42 } ?? false
        let batteryWarning =
            !snapshot.externalConnected && (snapshot.batteryLevel ?? 1) <= 0.15
        guard temperatureWarning || batteryWarning else { return }
        lock.lock()
        let canNotify = lastBatteryWarningDate.map {
            Date().timeIntervalSince($0) > 30 * 60
        } ?? true
        if canNotify { lastBatteryWarningDate = Date() }
        lock.unlock()
        guard canNotify else { return }
        if temperatureWarning {
            notify(
                title: "Mac 电池温度偏高",
                body: String(
                    format: "当前温度 %.1f°C，请留意散热与高负载应用。",
                    snapshot.temperatureCelsius ?? 0
                )
            )
        } else {
            notify(
                title: "Mac 电量较低",
                body: "当前仅剩 \(Int(((snapshot.batteryLevel ?? 0) * 100).rounded()))%，请连接电源。"
            )
        }
    }

    private func notify(title: String, body: String) {
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
