import Foundation
import SwiftData
import UserNotifications

/// Schedules, updates, and cancels local notifications for task reminders.
///
/// - Call `schedule(for:)` when a task is created or edited.
///   It cancels any existing pending requests for that task (including legacy
///   single-id requests and ad-hoc snooze notifications), then re-adds the
///   appropriate triggers.
/// - Call `cancel(taskID:)` when a task is deleted or marked complete.
///
/// Only tasks with a future, wall-clock-specific `scheduledDate` are eligible
/// (date-only / midnight is skipped).
///
/// For tasks with a specific time, two **non-overlapping** local notifications
/// may be used:
/// - **Pre** (`<uuid>_pre`) — `scheduledDate` minus `reminderOffsetMinutes`, only when
///   the offset is > 0 and the fire time is still in the future. No custom actions.
/// - **Exact** (`<uuid>_exact`) — at `scheduledDate` when that moment is still in the
///   future. Uses category `chattask.exact` with **Done** and **Snooze 10 min** actions.
/// - **Snoozed** (`<uuid>_snooze_<ts>`) — one-off follow-up from a snooze; title "Reminder", no pre / no actions.
///
/// **Delegate:** This class also acts as `UNUserNotificationCenterDelegate`.
/// `setup()` must be called once at app launch (from `ChatTaskApp.init`) to
/// register it before any notification can fire.  Without the delegate,
/// notifications that arrive while the app is in the **foreground** are silently
/// discarded by the system and never shown to the user.
final class TaskReminderService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = TaskReminderService()
    private let center = UNUserNotificationCenter.current()
    private var modelContainer: ModelContainer?

    // MARK: - Category / action identifiers (must match `didReceive` handling)

    private static let categoryExact = "chattask.exact"
    private static let actionDone = "chattask.action.done"
    private static let actionSnooze10 = "chattask.action.snooze10"

    private override init() {
        super.init()
    }

    /// Injects the app `ModelContainer` so notification actions can load/save `TaskItem`.
    /// Call before `setup()` (e.g. from `ChatTaskApp.init`).
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - App-launch setup

    /// Register delegate, category set, and foreground presentation.
    func setup() {
        center.delegate = self
        registerNotificationCategories()
        print("[Reminder] delegate registered — foreground presentation enabled")
        logAuthorizationStatus()
    }

    private func registerNotificationCategories() {
        let done = UNNotificationAction(
            identifier: Self.actionDone,
            title: "Done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.actionSnooze10,
            title: "Snooze 10 min",
            options: []
        )
        let exact = UNNotificationCategory(
            identifier: Self.categoryExact,
            actions: [done, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([exact])
        print("[Reminder] registered notification category '\(Self.categoryExact)' (Done, Snooze 10 min)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("[Reminder] willPresent foreground notification — id=\(notification.request.identifier) title='\(notification.request.content.title)'")
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        print("[Reminder] didReceive response — id=\(id) action=\(action)")

        if action == UNNotificationDefaultActionIdentifier
            || action == UNNotificationDismissActionIdentifier {
            completionHandler()
            return
        }

        if id.hasSuffix("_exact"), action == Self.actionDone || action == Self.actionSnooze10,
           let taskId = Self.parseBaseUUIDFromExactNotificationId(id) {
            Task { @MainActor in
                self.handleExactTimeAction(taskId: taskId, action: action)
                completionHandler()
            }
            return
        }

        completionHandler()
    }

    // MARK: - Public API

    func schedule(for task: TaskItem) {
        let ids = Self.notificationIdentifiers(for: task.id)
        // Pending enumeration is async; then schedule on the main actor with the SwiftData model.
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let toRemove = Self.removeIdList(
                base: ids.base,
                fixed: [ids.legacy, ids.pre, ids.exact],
                pending: requests
            )
            self.center.removePendingNotificationRequests(withIdentifiers: toRemove)
            Task { @MainActor in
                self.performScheduleAdditions(task: task, ids: ids)
            }
        }
    }

    func cancel(taskID: UUID) {
        let ids = Self.notificationIdentifiers(for: taskID)
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let toRemove = Self.removeIdList(
                base: ids.base,
                fixed: [ids.legacy, ids.pre, ids.exact],
                pending: requests
            )
            self.center.removePendingNotificationRequests(withIdentifiers: toRemove)
            print("[Reminder] cancel() — id=\(ids.base) removedIds=\(toRemove.count) (legacy+pre+exact+snoozes)")
        }
    }

    // MARK: - Debug helper

    func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "ChatTask Test Notification"
        content.body  = "Notification delivery is working ✓"
        content.sound = .default
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

    // MARK: - Action handling (main actor: SwiftData)

    @MainActor
    private func handleExactTimeAction(taskId: UUID, action: String) {
        guard let container = modelContainer else {
            print("[Reminder] action skipped — no ModelContainer (call configure) taskId=\(taskId)")
            return
        }
        let ctx = container.mainContext
        let tid = taskId
        var fetch = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })
        fetch.fetchLimit = 1
        guard let item = try? ctx.fetch(fetch).first else {
            print("[Reminder] action — task not found id=\(taskId)")
            return
        }
        if action == Self.actionDone {
            item.isCompleted = true
            item.completedAt = Date()
            item.updatedAt = Date()
            try? ctx.save()
            print("[Reminder] done action — task marked complete id=\(taskId)")
            cancel(taskID: taskId)
        } else if action == Self.actionSnooze10 {
            scheduleSnoozeNotification(taskId: taskId, taskTitle: item.title, base: taskId.uuidString)
        }
    }

    private func scheduleSnoozeNotification(taskId: UUID, taskTitle: String, base: String) {
        let ts = Int64(Date().timeIntervalSince1970 * 1_000)
        let notifId = base + "_snooze_\(ts)"
        let content = UNMutableNotificationContent()
        content.title = Self.snoozedReminderTitle
        content.body = taskTitle
        content.sound = .default
        // Intentionally no category (no follow-up snooze/done on snoozed alerts).
        content.userInfo = ["taskId": base]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: notifId, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                print("[Reminder] snooze add ERROR — id=\(notifId) error=\(error)")
            } else {
                print("[Reminder] snoozed reminder scheduled — id=\(notifId) taskId=\(base) in 10 min")
            }
        }
    }

    // MARK: - Schedule internals

    @MainActor
    private func performScheduleAdditions(task: TaskItem, ids: NotificationIDs) {
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

        if scheduledDate > now {
            let content = UNMutableNotificationContent()
            content.title = Self.exactTimeTitle
            content.body = task.title
            content.categoryIdentifier = Self.categoryExact
            content.sound = .default
            content.userInfo = ["taskId": ids.base]
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

    // MARK: - Private helpers

    private static let preReminderBody = "Starting soon"
    private static let exactTimeTitle = "It's time"
    private static let snoozedReminderTitle = "Reminder"

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

    private static func removeIdList(
        base: String,
        fixed: [String],
        pending: [UNNotificationRequest]
    ) -> [String] {
        var s = Set(fixed)
        let snoozePrefix = base + "_snooze_"
        for r in pending where r.identifier.hasPrefix(snoozePrefix) {
            s.insert(r.identifier)
        }
        return Array(s)
    }

    private static func parseBaseUUIDFromExactNotificationId(_ identifier: String) -> UUID? {
        guard identifier.hasSuffix("_exact") else { return nil }
        let base = String(identifier.dropLast(6)) // "_exact"
        return UUID(uuidString: base)
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
