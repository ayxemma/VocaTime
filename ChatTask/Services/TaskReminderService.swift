import Foundation
import UserNotifications

/// Schedules, updates, and cancels local notifications for task reminders.
///
/// - Call `schedule(for:)` when a task is created or edited.
///   It cancels any existing pending requests for that task (including legacy
///   single-id requests), then re-adds the appropriate triggers.
/// - Call `cancel(taskID:)` when a task is deleted or marked complete.
///
/// Only tasks with a future, wall-clock-specific `scheduledDate` are eligible
/// (date-only / midnight is skipped).
///
/// For tasks with a specific time, two **non-overlapping** local notifications
/// may be used:
/// - **Pre** (`<uuid>_pre`) — `scheduledDate` minus `reminderOffsetMinutes`, only when
///   the offset is > 0 and the fire time is still in the future.
/// - **Exact** (`<uuid>_exact`) — always at `scheduledDate` when that moment is
///   still in the future.
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
        let ids = Self.notificationIdentifiers(for: task.id)

        // Drop prior requests for this task (legacy single-id and current pre+exact).
        center.removePendingNotificationRequests(withIdentifiers: [ids.legacy, ids.pre, ids.exact])

        print("""
        [Reminder] schedule() — id=\(ids.base) title='\(task.title)' \
        scheduledDate=\(String(describing: task.scheduledDate)) \
        reminderOffsetMinutes=\(String(describing: task.reminderOffsetMinutes))
        """)

        guard !task.isCompleted else {
            print("[Reminder] skip — task is already completed (id=\(ids.base))")
            return
        }

        guard let scheduledDate = task.scheduledDate else {
            print("[Reminder] skip — no scheduledDate (id=\(ids.base))")
            return
        }

        guard hasWallClockTime(scheduledDate) else {
            print("[Reminder] skip — date-only task, no wall-clock time (id=\(ids.base), date=\(scheduledDate))")
            return
        }

        let offsetMinutes = task.reminderOffsetMinutes ?? ReminderOffset.globalDefault.rawValue
        let now = Date()

        // ── Pre-reminder: scheduledDate − offset; only if offset > 0 and not in the past. ──
        if offsetMinutes > 0 {
            let preFire = scheduledDate.addingTimeInterval(-Double(offsetMinutes) * 60)
            if preFire > now {
                let content = UNMutableNotificationContent()
                content.title = task.title
                content.body = Self.preReminderBody
                content.sound = .default
                let preComps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: preFire
                )
                let preTrigger = UNCalendarNotificationTrigger(dateMatching: preComps, repeats: false)
                let preRequest = UNNotificationRequest(
                    identifier: ids.pre,
                    content: content,
                    trigger: preTrigger
                )
                center.add(preRequest) { [weak self] error in
                    if let error {
                        print("[Reminder] ERROR pre-reminder add — id=\(ids.pre) error=\(error)")
                    } else {
                        print("[Reminder] pre-reminder scheduled — id=\(ids.pre) taskId=\(ids.base) fireDate=\(preFire)")
                        self?.center.getPendingNotificationRequests { requests in
                            let found = requests.contains { $0.identifier == ids.pre }
                            print("[Reminder] pendingVerify pre — id=\(ids.pre) foundInQueue=\(found) totalPending=\(requests.count)")
                        }
                    }
                }
            } else {
                print("[Reminder] skipped due to past time — kind=pre id=\(ids.pre) taskId=\(ids.base) triggerDate=\(preFire) now=\(now)")
            }
        }

        // ── Exact-time: always at scheduledDate when that instant is still in the future. ──
        if scheduledDate > now {
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = Self.exactReminderBody
            content.sound = .default
            let exactComps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: scheduledDate
            )
            let exactTrigger = UNCalendarNotificationTrigger(dateMatching: exactComps, repeats: false)
            let exactRequest = UNNotificationRequest(
                identifier: ids.exact,
                content: content,
                trigger: exactTrigger
            )
            center.add(exactRequest) { [weak self] error in
                if let error {
                    print("[Reminder] ERROR exact reminder add — id=\(ids.exact) error=\(error)")
                } else {
                    print("[Reminder] exact reminder scheduled — id=\(ids.exact) taskId=\(ids.base) fireDate=\(scheduledDate)")
                    self?.center.getPendingNotificationRequests { requests in
                        let found = requests.contains { $0.identifier == ids.exact }
                        print("[Reminder] pendingVerify exact — id=\(ids.exact) foundInQueue=\(found) totalPending=\(requests.count)")
                    }
                }
            }
        } else {
            print("[Reminder] skipped due to past time — kind=exact id=\(ids.exact) taskId=\(ids.base) triggerDate=\(scheduledDate) now=\(now)")
        }
    }

    func cancel(taskID: UUID) {
        let ids = Self.notificationIdentifiers(for: taskID)
        print("[Reminder] cancel() — id=\(ids.base) (legacy+pre+exact)")
        center.removePendingNotificationRequests(withIdentifiers: [ids.legacy, ids.pre, ids.exact])
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

    private static let preReminderBody = "Starting soon"
    private static let exactReminderBody = "It's time"

    private struct NotificationIDs {
        let base: String
        let legacy: String
        let pre: String
        let exact: String
    }

    private static func notificationIdentifiers(for id: UUID) -> NotificationIDs {
        let base = id.uuidString
        return NotificationIDs(
            base: base,
            legacy: base,
            pre: base + "_pre",
            exact: base + "_exact"
        )
    }

    private func hasWallClockTime(_ date: Date) -> Bool {
        let cal = Calendar.current
        return !(
            cal.component(.hour,   from: date) == 0 &&
            cal.component(.minute, from: date) == 0 &&
            cal.component(.second, from: date) == 0
        )
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
