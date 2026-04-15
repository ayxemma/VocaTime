import Foundation
import UserNotifications

/// Schedules, updates, and cancels local notifications for task reminders.
///
/// - Call `schedule(for:)` when a task is created or edited.
///   It always cancels any existing pending notification first, acting as an upsert.
/// - Call `cancel(taskID:)` when a task is deleted or marked complete.
///
/// Only tasks with a future, wall-clock-specific `scheduledDate` receive a notification.
/// Date-only tasks (midnight, no specific time) are intentionally skipped.
///
/// Lead time: the notification fires `reminderOffsetMinutes` before the task's
/// scheduled time. The offset is read from `task.reminderOffsetMinutes` if set,
/// otherwise from the global default (`ReminderOffset.globalDefault`).
///
/// **Delegate:** This class also acts as `UNUserNotificationCenterDelegate`.
/// `setup()` must be called once at app launch (from `ChatTaskApp.init`) to
/// register it before any notification can fire.  Without the delegate,
/// notifications that arrive while the app is in the **foreground** are silently
/// discarded by the system and never shown to the user.
final class TaskReminderService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = TaskReminderService()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    // MARK: - App-launch setup

    /// Register this object as the notification-center delegate.
    /// Must be called as early as possible — ideally in `ChatTaskApp.init()` —
    /// so the delegate is in place before the first notification fires.
    func setup() {
        center.delegate = self
        print("[Reminder] delegate registered — foreground presentation enabled")
        logAuthorizationStatus()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app is in the **foreground**.
    /// Without this implementation the system discards the notification silently.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("[Reminder] willPresent foreground notification — id=\(notification.request.identifier) title='\(notification.request.content.title)'")
        // Show banner + play sound even when the app is open.
        completionHandler([.banner, .sound, .list])
    }

    /// Called when the user taps a delivered notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print("[Reminder] didReceive tap on notification — id=\(response.notification.request.identifier)")
        completionHandler()
    }

    // MARK: - Public API

    func schedule(for task: TaskItem) {
        let identifier = task.id.uuidString

        // Always cancel the existing pending notification for this task first (upsert).
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        print("""
        [Reminder] schedule() — id=\(identifier) title='\(task.title)' \
        scheduledDate=\(String(describing: task.scheduledDate)) \
        reminderOffsetMinutes=\(String(describing: task.reminderOffsetMinutes))
        """)

        guard !task.isCompleted else {
            print("[Reminder] skip — task is already completed (id=\(identifier))")
            return
        }

        guard let scheduledDate = task.scheduledDate else {
            print("[Reminder] skip — no scheduledDate (id=\(identifier))")
            return
        }

        guard hasWallClockTime(scheduledDate) else {
            print("[Reminder] skip — date-only task, no wall-clock time (id=\(identifier), date=\(scheduledDate))")
            return
        }

        let offsetMinutes = task.reminderOffsetMinutes ?? ReminderOffset.globalDefault.rawValue
        let fireDate = scheduledDate.addingTimeInterval(-Double(offsetMinutes) * 60)

        print("""
        [Reminder] trigger computed — id=\(identifier) \
        scheduledDate=\(scheduledDate) \
        offsetMin=\(offsetMinutes) \
        fireDate=\(fireDate) \
        now=\(Date()) \
        isFuture=\(fireDate > Date())
        """)

        guard fireDate > Date() else {
            print("[Reminder] skip — triggerDate \(fireDate) is in the past (id=\(identifier))")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body  = formattedBody(scheduledDate: scheduledDate, offsetMinutes: offsetMinutes)
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger  = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request  = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request) { [weak self] error in
            if let error {
                print("[Reminder] ERROR adding notification — id=\(identifier) error=\(error)")
            } else {
                print("[Reminder] scheduled ✓ — id=\(identifier) fireDate=\(fireDate) offset=\(offsetMinutes)min")
                // Verify the request actually landed in the pending queue.
                self?.center.getPendingNotificationRequests { requests in
                    let found = requests.contains { $0.identifier == identifier }
                    print("[Reminder] pendingVerify — id=\(identifier) foundInQueue=\(found) totalPending=\(requests.count)")
                }
            }
        }
    }

    func cancel(taskID: UUID) {
        let identifier = taskID.uuidString
        print("[Reminder] cancel() — id=\(identifier)")
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Debug helper

    /// Schedules a test notification 10 seconds from now.
    /// Use this to verify end-to-end local notification delivery independently
    /// of task scheduling logic.  Remove or gate behind a debug flag before shipping.
    func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "ChatTask Test Notification"
        content.body  = "Notification delivery is working ✓"
        content.sound = .default
        // UNTimeIntervalNotificationTrigger fires regardless of calendar time,
        // making it the most reliable test trigger on both simulator and device.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(
            identifier: "chattask.debug.test",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                print("[Reminder] testNotification ERROR — \(error)")
            } else {
                print("[Reminder] testNotification scheduled — will fire in ~10 seconds")
            }
        }
        print("[Reminder] scheduleTestNotification() called — background the app to see the banner (or keep it open — foreground delivery is now enabled)")
    }

    // MARK: - Private helpers

    private func hasWallClockTime(_ date: Date) -> Bool {
        let cal = Calendar.current
        return !(
            cal.component(.hour,   from: date) == 0 &&
            cal.component(.minute, from: date) == 0 &&
            cal.component(.second, from: date) == 0
        )
    }

    /// Builds the notification body.
    /// - 0 min offset → "Now · 5:15 PM"
    /// - N min offset → "In N min · 5:15 PM"  (or "In 1 hr · 5:15 PM" for 60)
    private func formattedBody(scheduledDate: Date, offsetMinutes: Int) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let timeString = f.string(from: scheduledDate)

        switch offsetMinutes {
        case 0:  return "Now · \(timeString)"
        case 60: return "In 1 hr · \(timeString)"
        default: return "In \(offsetMinutes) min · \(timeString)"
        }
    }

    private func logAuthorizationStatus() {
        center.getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "notDetermined — permission not yet requested"
            case .denied:        status = "denied — user has blocked notifications; reminders will not fire"
            case .authorized:    status = "authorized ✓"
            case .provisional:   status = "provisional — delivered quietly to Notification Center"
            case .ephemeral:     status = "ephemeral ✓"
            @unknown default:    status = "unknown (\(settings.authorizationStatus.rawValue))"
            }
            print("[Reminder] notificationAuthorizationStatus = \(status)")
            print("""
            [Reminder] notificationSettings \
            alertSetting=\(settings.alertSetting.rawValue) \
            soundSetting=\(settings.soundSetting.rawValue) \
            badgeSetting=\(settings.badgeSetting.rawValue) \
            lockScreenSetting=\(settings.lockScreenSetting.rawValue) \
            notificationCenterSetting=\(settings.notificationCenterSetting.rawValue)
            """)
        }
    }
}
