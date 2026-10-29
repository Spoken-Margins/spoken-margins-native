import Foundation
import UserNotifications

/// "It's still going" (#2709 point 4): the listener opened the End screen but the meeting is still on, so the session
/// stays running and one reminder comes later. It only uses a permission the listener has already given; it never
/// asks for one, and without it the session simply keeps running.
enum LiveSessionStillGoingReminder {
    static let identifier = "liveSession.stillGoing"
    /// Default taken: fifteen minutes, long enough not to nag during a meeting and short enough to catch its end.
    static let delay: TimeInterval = 15 * 60

    /// Schedules the one reminder, replacing any earlier. False when notifications aren't allowed or couldn't be set.
    @MainActor
    static func schedule() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Is it still going?"
        // No title: a notification shows on the Lock Screen.
        content.body = "Your live session is still running in Spoken Margins. Open it to end the session."
        do {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            try await center.add(UNNotificationRequest(
                identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            ))
            return true
        } catch {
            return false
        }
    }

    /// Drops the reminder: the session ended, was discarded or was saved.
    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
