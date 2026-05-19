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
/// One-off tasks need a future, wall-clock-specific `scheduledDate`.
/// Recurring weekly tasks use recurrence metadata and schedule the next 14
/// occurrence notifications as one-off calendar triggers.
///
/// For tasks with a specific time, two **non-overlapping** local notifications
/// may be used:
/// - **Pre** (`<uuid>_pre`) — `scheduledDate` minus `reminderOffsetMinutes`, only when
///   the offset is > 0 and the fire time is still in the future. No custom actions.
/// - **Exact** (`<uuid>_exact`) — at `scheduledDate` when that moment is still in the
///   future. Uses category `chattask.exact` with **Done** and **Snooze 10 min** actions.
/// - **Recurring** (`<uuid>_rec_<n>_pre`, `<uuid>_rec_<n>_exact`) — next 14 weekly
///   occurrences only, still using exact + pre behavior.
/// - **Snoozed** (`<uuid>_snooze_<ts>`) — one-off follow-up from a snooze; title "Reminder", no pre / no actions.
/// - **Important follow-up** (`<exact-id>_followup`) — optional second alert 2 min after an exact fire time when alert style is Important.
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
        let content = notification.request.content
        print("""
        [Reminder] willPresent foreground notification — id=\(notification.request.identifier) \
        title='\(content.title)' sound=\(content.sound == nil ? "nil" : "default") \
        interruptionLevel=\(content.interruptionLevel.rawValue)
        """)
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
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
            print("[Reminder] cancel() — id=\(ids.base) removedIds=\(toRemove.count) (legacy+pre+exact+snoozes+recurrence)")
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
            scheduleSnoozeNotification(taskId: taskId, taskTitle: item.title, base: taskId.uuidString, alertStyle: item.alertStyle)
        }
    }

    private func scheduleSnoozeNotification(taskId: UUID, taskTitle: String, base: String, alertStyle: ReminderAlertStyle) {
        let ts = Int64(Date().timeIntervalSince1970 * 1_000)
        let notifId = base + "_snooze_\(ts)"
        let content = UNMutableNotificationContent()
        content.title = Self.snoozedReminderTitle
        content.body = taskTitle
        applyAlertStyle(alertStyle, to: content)
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
        reminderOffsetMinutes=\(String(describing: task.reminderOffsetMinutes)) \
        alertStyle=\(task.alertStyle.rawValue)
        """)

        guard !task.isCompleted else {
            print("[Reminder] skip — task is already completed (id=\(ids.base))")
            return
        }

        if task.isRecurring {
            performRecurringScheduleAdditions(task: task, ids: ids)
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
                addPreReminderRequest(
                    identifier: ids.pre,
                    taskID: ids.base,
                    taskTitle: task.title,
                    fireDate: preFire,
                    calendar: .current,
                    alertStyle: task.alertStyle
                )
            } else {
                print("[Reminder] skipped due to past time — kind=pre id=\(ids.pre) taskId=\(ids.base) triggerDate=\(preFire) now=\(now)")
            }
        }

        if scheduledDate > now {
            addExactReminderRequest(
                identifier: ids.exact,
                taskID: ids.base,
                taskTitle: task.title,
                fireDate: scheduledDate,
                calendar: .current,
                alertStyle: task.alertStyle
            )
        } else {
            print("[Reminder] skipped due to past time — kind=exact id=\(ids.exact) taskId=\(ids.base) triggerDate=\(scheduledDate) now=\(now)")
        }
    }

    private func performRecurringScheduleAdditions(task: TaskItem, ids: NotificationIDs) {
        guard task.recurrenceFrequency == .weekly else {
            print("[Reminder] recurring skip — unsupported frequency id=\(ids.base) frequency=\(String(describing: task.recurrenceFrequency))")
            return
        }

        guard let timeMinutes = task.recurrenceTimeMinutes,
              (0..<(24 * 60)).contains(timeMinutes)
        else {
            print("[Reminder] recurring skip — missing/invalid time id=\(ids.base) timeMinutes=\(String(describing: task.recurrenceTimeMinutes))")
            return
        }

        let weekdays = task.recurrenceWeekdays
        guard !weekdays.isEmpty else {
            print("[Reminder] recurring skip — no weekdays id=\(ids.base)")
            return
        }

        let offsetMinutes = task.reminderOffsetMinutes ?? ReminderOffset.globalDefault.rawValue
        let calendar = recurrenceCalendar(for: task)
        let now = Date()
        let occurrences = nextWeeklyOccurrences(
            weekdays: weekdays,
            timeMinutes: timeMinutes,
            startDate: task.recurrenceStartDate,
            endDate: task.recurrenceEndDate,
            now: now,
            calendar: calendar,
            limit: Self.recurrenceOccurrenceLimit
        )

        print("""
        [Reminder] recurring schedule — id=\(ids.base) title='\(task.title)' \
        weekdays=\(weekdays) timeMinutes=\(timeMinutes) \
        timezone=\(calendar.timeZone.identifier) occurrences=\(occurrences.count) \
        reminderOffsetMinutes=\(offsetMinutes)
        """)

        for (index, occurrence) in occurrences.enumerated() {
            if offsetMinutes > 0 {
                let preFire = occurrence.addingTimeInterval(-Double(offsetMinutes) * 60)
                if preFire > now {
                    addPreReminderRequest(
                        identifier: Self.recurringNotificationIdentifier(base: ids.base, index: index, kind: "pre"),
                        taskID: ids.base,
                        taskTitle: task.title,
                        fireDate: preFire,
                        calendar: calendar,
                        alertStyle: task.alertStyle
                    )
                } else {
                    print("[Reminder] recurring skipped due to past time — kind=pre taskId=\(ids.base) occurrence=\(occurrence) triggerDate=\(preFire) now=\(now)")
                }
            }

            addExactReminderRequest(
                identifier: Self.recurringNotificationIdentifier(base: ids.base, index: index, kind: "exact"),
                taskID: ids.base,
                taskTitle: task.title,
                fireDate: occurrence,
                calendar: calendar,
                alertStyle: task.alertStyle
            )
        }
    }

    // MARK: - Private helpers

    private static let preReminderBody = "Starting soon"
    private static let exactTimeTitle = "It's time"
    private static let snoozedReminderTitle = "Reminder"
    private static let recurrenceOccurrenceLimit = 14
    /// Extra nudge for Important reminders (after the exact-time notification).
    private static let importantFollowUpDelay: TimeInterval = 2 * 60

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
        let taskPrefix = base + "_"
        for r in pending where r.identifier == base || r.identifier.hasPrefix(taskPrefix) {
            s.insert(r.identifier)
        }
        return Array(s)
    }

    private static func parseBaseUUIDFromExactNotificationId(_ identifier: String) -> UUID? {
        guard identifier.hasSuffix("_exact") else { return nil }
        let withoutSuffix = String(identifier.dropLast(6)) // "_exact"
        let base = withoutSuffix.components(separatedBy: "_rec_").first ?? withoutSuffix
        return UUID(uuidString: base)
    }

    private static func recurringNotificationIdentifier(base: String, index: Int, kind: String) -> String {
        "\(base)_rec_\(index)_\(kind)"
    }

    private func addPreReminderRequest(
        identifier: String,
        taskID: String,
        taskTitle: String,
        fireDate: Date,
        calendar: Calendar,
        alertStyle: ReminderAlertStyle
    ) {
        let content = UNMutableNotificationContent()
        content.title = taskTitle
        content.body = Self.preReminderBody
        applyAlertStyle(alertStyle, to: content)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { [weak self] error in
            if let error {
                print("[Reminder] ERROR pre-reminder add — id=\(identifier) error=\(error)")
            } else {
                print("[Reminder] pre-reminder scheduled — id=\(identifier) taskId=\(taskID) fireDate=\(fireDate)")
                self?.verifyPendingRequest(identifier: identifier, kind: "pre")
            }
        }
    }

    private func addExactReminderRequest(
        identifier: String,
        taskID: String,
        taskTitle: String,
        fireDate: Date,
        calendar: Calendar,
        alertStyle: ReminderAlertStyle
    ) {
        let content = UNMutableNotificationContent()
        content.title = Self.exactTimeTitle
        content.body = taskTitle
        content.categoryIdentifier = Self.categoryExact
        applyAlertStyle(alertStyle, to: content)
        content.userInfo = ["taskId": taskID]
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { [weak self] error in
            if let error {
                print("[Reminder] ERROR exact reminder add — id=\(identifier) error=\(error)")
            } else {
                print("[Reminder] exact reminder scheduled — id=\(identifier) taskId=\(taskID) fireDate=\(fireDate)")
                self?.verifyPendingRequest(identifier: identifier, kind: "exact")
            }
        }

        scheduleImportantFollowUpIfNeeded(
            exactIdentifier: identifier,
            taskID: taskID,
            taskTitle: taskTitle,
            fireDate: fireDate,
            calendar: calendar,
            alertStyle: alertStyle
        )
    }

    private func scheduleImportantFollowUpIfNeeded(
        exactIdentifier: String,
        taskID: String,
        taskTitle: String,
        fireDate: Date,
        calendar: Calendar,
        alertStyle: ReminderAlertStyle
    ) {
        guard alertStyle == .important else { return }
        let followUpFire = fireDate.addingTimeInterval(Self.importantFollowUpDelay)
        guard followUpFire > Date() else {
            print("[Reminder] important follow-up skipped — past fireDate=\(followUpFire)")
            return
        }
        let identifier = exactIdentifier + "_followup"
        let content = UNMutableNotificationContent()
        content.title = Self.snoozedReminderTitle
        content.body = taskTitle
        applyAlertStyle(alertStyle, to: content)
        content.userInfo = ["taskId": taskID]
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: followUpFire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                print("[Reminder] ERROR important follow-up add — id=\(identifier) error=\(error)")
            } else {
                print("[Reminder] important follow-up scheduled — id=\(identifier) taskId=\(taskID) fireDate=\(followUpFire)")
            }
        }
    }

    private func applyAlertStyle(_ style: ReminderAlertStyle, to content: UNMutableNotificationContent) {
        print("[Reminder] notificationAlertStyleApplied style=\(style.rawValue)")
        switch style {
        case .silent:
            content.sound = nil
            content.interruptionLevel = .passive
            print("[Reminder] notificationSoundApplied sound=nil")
            logInterruptionLevel(.passive)
        case .default:
            content.sound = .default
            content.interruptionLevel = .active
            print("[Reminder] notificationSoundApplied sound=default")
            logInterruptionLevel(.active)
        case .important:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            print("[Reminder] notificationSoundApplied sound=default")
            logInterruptionLevel(.timeSensitive)
        }
    }

    private func logInterruptionLevel(_ level: UNNotificationInterruptionLevel) {
        let label: String
        switch level {
        case .passive: label = "passive"
        case .active: label = "active"
        case .timeSensitive: label = "timeSensitive"
        case .critical: label = "critical"
        @unknown default: label = "unknown(\(level.rawValue))"
        }
        print("[Reminder] notificationInterruptionLevelApplied level=\(label)")
    }

    private func verifyPendingRequest(identifier: String, kind: String) {
        center.getPendingNotificationRequests { requests in
            let found = requests.contains { $0.identifier == identifier }
            print("[Reminder] pendingVerify \(kind) — id=\(identifier) foundInQueue=\(found) totalPending=\(requests.count)")
        }
    }

    private func recurrenceCalendar(for task: TaskItem) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let tz = task.recurrenceTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) {
            calendar.timeZone = tz
        } else {
            calendar.timeZone = .current
        }
        return calendar
    }

    private func nextWeeklyOccurrences(
        weekdays: [Int],
        timeMinutes: Int,
        startDate: Date?,
        endDate: Date?,
        now: Date,
        calendar: Calendar,
        limit: Int
    ) -> [Date] {
        let weekdaySet = Set(weekdays.filter { (1...7).contains($0) })
        guard !weekdaySet.isEmpty, limit > 0 else { return [] }

        let hour = timeMinutes / 60
        let minute = timeMinutes % 60
        let effectiveStart = maxDate(now, startDate)
        var day = calendar.startOfDay(for: effectiveStart)
        var results: [Date] = []
        var scannedDays = 0

        while results.count < limit && scannedDays < Self.maxRecurrenceSearchDays {
            let isoWeekday = self.isoWeekday(for: day, calendar: calendar)
            if weekdaySet.contains(isoWeekday) {
                var comps = calendar.dateComponents([.year, .month, .day], from: day)
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                if let occurrence = calendar.date(from: comps),
                   occurrence > now,
                   occurrence >= effectiveStart,
                   endDate.map({ occurrence <= $0 }) ?? true {
                    results.append(occurrence)
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
            scannedDays += 1
        }

        return results
    }

    private static let maxRecurrenceSearchDays = 370

    private func isoWeekday(for date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    private func maxDate(_ lhs: Date, _ rhs: Date?) -> Date {
        guard let rhs else { return lhs }
        return lhs > rhs ? lhs : rhs
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
            notificationCenterSetting=\(settings.notificationCenterSetting.rawValue) \
            timeSensitiveSetting=\(settings.timeSensitiveSetting.rawValue)
            """)
        }
    }
}
