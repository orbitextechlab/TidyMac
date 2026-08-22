import Foundation
import UserNotifications

/// Thin wrapper over UserNotifications for temperature alerts. Requests
/// authorization lazily on first use.
final class NotificationService {
    static let shared = NotificationService()
    private var authorized = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    func postTemperatureAlert(celsius: Double) {
        let content = UNMutableNotificationContent()
        content.title = "High Temperature"
        content.body = String(format: "CPU is running at %.0f°C.", celsius)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "temp-\(Int(celsius))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
