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

    /// Every scheduled run reports itself, whether or not it removed anything.
    /// An unattended clean the user never hears about is the failure mode this
    /// avoids: they should always be able to tell what the app did while they
    /// were not looking.
    func postScheduledRunComplete(foundBytes: Int64, freedBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Scheduled Cleanup"
        content.body = freedBytes > 0
            ? "Moved \(Format.bytes(freedBytes)) to the Trash. "
              + "\(Format.bytes(foundBytes)) found in total."
            : "Found \(Format.bytes(foundBytes)) to review. Nothing was removed."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "schedule-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
