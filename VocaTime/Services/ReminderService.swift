import Foundation
import UserNotifications

private func reminderServiceError(_ message: String) -> Error {
    NSError(domain: "VocaTimeReminder", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Schedules local notifications via `UNUserNotificationCenter`.
@MainActor
final class ReminderService {
    private let center = UNUserNotificationCenter.current()

    /// Ensures the user has granted alert permission (requests once if needed).
    func requestPermissionIfNeeded() async -> Result<Void, Error> {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .success(())
        case .denied:
            return .failure(
                reminderServiceError(
                    "Notifications are turned off. Enable them in Settings → Notifications → VocaTime."
                )
            )
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    return .success(())
                }
                return .failure(
                    reminderServiceError("Notifications were not allowed. You can enable them in Settings.")
                )
            } catch {
                return .failure(error)
            }
        @unknown default:
            return .failure(reminderServiceError("Notifications are not available."))
        }
    }

    /// Schedules a one-shot notification at the given date (wall clock in `calendar`).
    func scheduleReminder(
        title: String,
        notes: String?,
        at fireDate: Date,
        calendar: Calendar = .current
    ) async -> Result<Void, Error> {
        switch await requestPermissionIfNeeded() {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }

        if fireDate <= Date() {
            return .failure(reminderServiceError("That time is already in the past. Try speaking a new command."))
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = notes
        }
        content.sound = .default

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
