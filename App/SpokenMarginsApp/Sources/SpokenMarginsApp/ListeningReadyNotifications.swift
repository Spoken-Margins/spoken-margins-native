import Foundation
import UserNotifications

final class ListeningReadyNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ListeningReadyNotifications()
    @MainActor static var pendingItemID: String?
    @MainActor static let opened = Notification.Name("ListeningEditionReadyOpened")

    @MainActor static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    @MainActor static func notify(itemID: String, title: String, revision: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let key = "listeningEditionNotification:" + revision
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ready to listen"
        content.body = title
        content.userInfo = ["listeningEditionItemID": itemID]
        do {
            try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            UserDefaults.standard.set(true, forKey: key)
        } catch { /* In-app audio readiness remains available if notifications fail. */ }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let itemID = response.notification.request.content.userInfo["listeningEditionItemID"] as? String
        Task { @MainActor in
            if let itemID {
                Self.pendingItemID = itemID
                NotificationCenter.default.post(name: Self.opened, object: nil)
            }
        }
        completionHandler()
    }
}
