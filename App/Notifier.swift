import BatteryLensKit
import UserNotifications

/// Shows AlertMonitor's alerts as notifications. Clicking one opens that device's settings.
/// The app's one notification delegate, so it also routes clicks on update notices.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ alert: AlertMonitor.Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.kind == .low ? .default : nil
        content.userInfo = ["device": alert.deviceID]
        let request = UNNotificationRequest(identifier: "\(alert.kind.rawValue)/\(alert.deviceID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // A menu bar app counts as active whenever its menu is open; show alerts anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == AutoUpdater.notificationCategory {
            // Clicking an update notice or its Install button opens the usual confirmation.
            DispatchQueue.main.async { UpdateController.checkForUpdates() }
        } else if let device = response.notification.request.content.userInfo["device"] as? String {
            DispatchQueue.main.async { self.onOpen?(device) }
        }
        completionHandler()
    }
}
