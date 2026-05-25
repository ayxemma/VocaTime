import Foundation
import SwiftData

enum TaskKind: String, Codable, CaseIterable {
    case task
    case reminder
    case event
}

enum TaskSource: String, Codable, CaseIterable {
    case voice
    case manual
}

enum ReminderAlertStyle: String, Codable, CaseIterable, Identifiable {
    case normal
    case important

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .important: return "Important"
        }
    }

    /// Stored `alertStyleRaw` and legacy values → `normal` or `important`.
    static func resolved(fromRaw raw: String?) -> ReminderAlertStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .normal
        }
        if let legacy = migrateLegacyStoredRawValue(raw) {
            return legacy
        }
        if let style = ReminderAlertStyle(rawValue: raw) {
            return style
        }
        return parsed(fromRaw: raw) ?? .normal
    }

    /// Parses voice/LLM aliases; returns nil when the string is not a known alert style.
    static func parsed(fromRaw raw: String?) -> ReminderAlertStyle? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let legacy = migrateLegacyStoredRawValue(raw) {
            return legacy
        }
        if let style = ReminderAlertStyle(rawValue: raw) {
            return style
        }
        let collapsed = raw
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        switch collapsed {
        case "silent", "quiet", "nosound", "mute", "muted", "静音", "不要声音",
             "default", "normal", "standard", "普通", "普通提醒",
             "sound", "soundonly", "vibration", "vibrate", "vibrationonly", "vibrateonly":
            return .normal
        case "important", "loud", "strong", "alarmlike",
             "soundandvibration", "soundvibration", "sound+vibration",
             "重要", "重要提醒", "明显一点", "聲音大一點", "声音大一点":
            return .important
        default:
            return nil
        }
    }

    private static func migrateLegacyStoredRawValue(_ raw: String) -> ReminderAlertStyle? {
        switch raw {
        case "silent", "default":
            return .normal
        default:
            return nil
        }
    }
}

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String?
    var scheduledDate: Date?
    var endDate: Date?
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var sourceRaw: String
    var kindRaw: String
    /// Per-task reminder lead time in minutes. `nil` means use the global default.
    var reminderOffsetMinutes: Int?
    /// Product-facing alert importance. Nil/unknown preserves the app's previous default sound behavior.
    var alertStyleRaw: String?
    var alertSoundName: String?
    /// Optional recurrence metadata. Nil means this task is a one-off task/reminder.
    var recurrenceFrequencyRaw: String?
    /// ISO weekdays stored as a comma-separated list: Monday = 1 ... Sunday = 7.
    var recurrenceWeekdaysRaw: String?
    /// Wall-clock recurrence time as minutes after midnight in `recurrenceTimeZoneIdentifier`.
    var recurrenceTimeMinutes: Int?
    var recurrenceTimeZoneIdentifier: String?
    var recurrenceStartDate: Date?
    var recurrenceEndDate: Date?

    /// Apple Calendar / EventKit event identifier when this task is synced out.
    var calendarEventIdentifier: String?
    /// `EKCalendar.calendarIdentifier` used for the synced event.
    var calendarIdentifier: String?
    /// When true and global sync is on, this timed task may create/update a calendar event.
    var calendarSyncEnabled: Bool = false
    /// e.g. `"apple"` for EventKit-created events from ChatTask.
    var externalCalendarSource: String?

    var kind: TaskKind {
        TaskKind(rawValue: kindRaw) ?? .task
    }

    var source: TaskSource {
        TaskSource(rawValue: sourceRaw) ?? .voice
    }

    var recurrenceFrequency: RecurrenceFrequency? {
        guard let recurrenceFrequencyRaw else { return nil }
        return RecurrenceFrequency(rawValue: recurrenceFrequencyRaw)
    }

    var alertStyle: ReminderAlertStyle {
        get { ReminderAlertStyle.resolved(fromRaw: alertStyleRaw) }
        set {
            alertStyleRaw = newValue.rawValue
            alertSoundName = nil
        }
    }

    var recurrenceWeekdays: [Int] {
        Self.decodeRecurrenceWeekdays(recurrenceWeekdaysRaw)
    }

    var isRecurring: Bool {
        recurrenceFrequency != nil
    }

    /// True when the task uses the Important reminder alert style (UI priority indicator).
    var hasImportantPriority: Bool {
        alertStyle == .important
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        scheduledDate: Date? = nil,
        endDate: Date? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        source: TaskSource = .voice,
        kind: TaskKind = .task,
        reminderOffsetMinutes: Int? = nil,
        alertStyle: ReminderAlertStyle = .normal,
        alertSoundName: String? = nil,
        recurrenceFrequency: RecurrenceFrequency? = nil,
        recurrenceWeekdays: [Int] = [],
        recurrenceTimeMinutes: Int? = nil,
        recurrenceTimeZoneIdentifier: String? = nil,
        recurrenceStartDate: Date? = nil,
        recurrenceEndDate: Date? = nil,
        calendarEventIdentifier: String? = nil,
        calendarIdentifier: String? = nil,
        calendarSyncEnabled: Bool = false,
        externalCalendarSource: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.scheduledDate = scheduledDate
        self.endDate = endDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceRaw = source.rawValue
        self.kindRaw = kind.rawValue
        self.reminderOffsetMinutes = reminderOffsetMinutes
        self.alertStyleRaw = alertStyle.rawValue
        self.alertSoundName = alertSoundName
        self.recurrenceFrequencyRaw = recurrenceFrequency?.rawValue
        self.recurrenceWeekdaysRaw = Self.encodeRecurrenceWeekdays(recurrenceWeekdays)
        self.recurrenceTimeMinutes = recurrenceTimeMinutes
        self.recurrenceTimeZoneIdentifier = recurrenceTimeZoneIdentifier
        self.recurrenceStartDate = recurrenceStartDate
        self.recurrenceEndDate = recurrenceEndDate
        self.calendarEventIdentifier = calendarEventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.calendarSyncEnabled = calendarSyncEnabled
        self.externalCalendarSource = externalCalendarSource
    }

    @MainActor
    @discardableResult
    static func insertFromParsedCommand(_ command: ParsedCommand, context: ModelContext) -> TaskItem {
        let kind: TaskKind
        switch command.actionType {
        case .reminder: kind = .reminder
        case .calendarEvent: kind = .event
            case .unknown, .deleteTask, .rescheduleTask, .appendToTask, .updateTaskTitle, .updateRecurrence, .updateAlertStyle: kind = .task
        }
        let now = Date()
        let item = TaskItem(
            title: command.title,
            notes: command.notes,
            scheduledDate: command.reminderDate ?? command.startDate,
            endDate: command.endDate,
            isCompleted: false,
            completedAt: nil,
            createdAt: now,
            updatedAt: now,
            source: .voice,
            kind: kind,
            reminderOffsetMinutes: command.reminderOffsetMinutes ?? ReminderOffset.globalDefault.rawValue,
            alertStyle: command.alertStyle ?? .normal,
            recurrenceFrequency: command.recurrence?.frequency,
            recurrenceWeekdays: command.recurrence?.weekdays ?? [],
            recurrenceTimeMinutes: command.recurrence?.timeMinutes,
            recurrenceTimeZoneIdentifier: command.recurrence?.timeZoneIdentifier,
            recurrenceStartDate: command.recurrence?.startDate,
            recurrenceEndDate: command.recurrence?.endDate
        )
        context.insert(item)
        try? context.save()
        TaskReminderService.shared.schedule(for: item)
        CalendarSyncService.shared.applyOutboundEligibility(for: item)
        CalendarSyncService.shared.syncOutbound(for: item, modelContext: context)
        return item
    }

    private static func encodeRecurrenceWeekdays(_ weekdays: [Int]) -> String? {
        let sanitized = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        guard !sanitized.isEmpty else { return nil }
        return sanitized.map(String.init).joined(separator: ",")
    }

    private static func decodeRecurrenceWeekdays(_ raw: String?) -> [Int] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return raw
            .split(separator: ",")
            .compactMap { Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { (1...7).contains($0) }
    }
}
