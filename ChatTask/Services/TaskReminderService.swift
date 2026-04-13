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
struct TaskReminderService {
    static let shared = TaskReminderService()
    private init() {}

    private let center = UNUserNotificationCenter.current()

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
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request  = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request) { error in
            if let error {
                print("[Reminder] ERROR adding notification — id=\(identifier) error=\(error)")
            } else {
                print("[Reminder] scheduled ✓ — id=\(identifier) triggerDate=\(fireDate) offset=\(offsetMinutes)min")
            }
        }
    }

    func cancel(taskID: UUID) {
        let identifier = taskID.uuidString
        print("[Reminder] cancel() — id=\(identifier)")
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Helpers

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
}
