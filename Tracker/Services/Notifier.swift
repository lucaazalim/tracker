import Foundation
import UserNotifications

/// Local notifications for tracker events and the "tracking stopped" watchdog.
final class Notifier: NSObject {
    private let center = UNUserNotificationCenter.current()
    private var lastWatchdogSchedule: Date?
    private var lastUploadFailure: (message: String, date: Date)?

    private static let watchdogIdentifier = "watchdog"

    override init() {
        super.init()
        center.delegate = self
    }

    var authorizationStatus: UNAuthorizationStatus {
        get async { await center.notificationSettings().authorizationStatus }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Notifies about an upload failure, at most once per distinct message per hour.
    func postUploadFailure(_ message: String) {
        if let last = lastUploadFailure, last.message == message, Date.now.timeIntervalSince(last.date) < 3600 { return }
        lastUploadFailure = (message, .now)
        post(title: "Upload failed", body: message, identifier: "upload-failed")
    }

    func clearUploadFailure() {
        lastUploadFailure = nil
    }

    // MARK: Watchdog

    /// (Re)schedules the watchdog. Called on every location update, rate-limited to once a minute.
    func armWatchdog(minutes: Int) {
        if let last = lastWatchdogSchedule, Date.now.timeIntervalSince(last) < 60 { return }
        lastWatchdogSchedule = .now

        let content = UNMutableNotificationContent()
        content.title = "Tracking stopped"
        content.body = "No location received for \(minutes) minutes. Open Tracker to resume."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(minutes, 1) * 60), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.watchdogIdentifier, content: content, trigger: trigger))
    }

    func disarmWatchdog() {
        lastWatchdogSchedule = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.watchdogIdentifier])
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners while the app is in the foreground too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
