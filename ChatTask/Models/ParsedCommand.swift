import Foundation

enum ActionType: String, CaseIterable, Equatable {
    // ── Create ────────────────────────────────────────────────
    case reminder
    case calendarEvent
    case unknown
    // ── Edit (voice-based task editing) ──────────────────────
    case deleteTask
    case rescheduleTask
    case appendToTask
    case updateTaskTitle
    case updateRecurrence
    case updateAlertStyle
}

enum ParserSource: String, Codable, Equatable {
    case local
    case llm
    case unknown
}

enum TargetReferenceType: String, Codable, Equatable {
    case taskID = "task_id"
    case recentTask = "recent_task"
    case time
    case title
    case unknown
}

enum RecurrenceFrequency: String, Codable, Equatable, CaseIterable {
    case weekly
}

enum RecurrenceUpdateOperation: String, Codable, Equatable {
    case setWeekdays
    case addWeekdays
    case removeWeekdays
    case setTime
    case clearRecurrence
    case unknown
}

struct ParsedRecurrence: Codable, Equatable {
    var frequency: RecurrenceFrequency
    /// ISO weekdays: Monday = 1 ... Sunday = 7.
    var weekdays: [Int]
    /// Wall-clock fire time as minutes after midnight in the task timezone.
    var timeMinutes: Int?
    var timeZoneIdentifier: String?
    var startDate: Date?
    var endDate: Date?
}

struct ParsedRecurrenceUpdate: Codable, Equatable {
    var operation: RecurrenceUpdateOperation
    /// ISO weekdays: Monday = 1 ... Sunday = 7.
    var weekdays: [Int]?
    /// Replacement wall-clock fire time as minutes after midnight in the task timezone.
    var timeMinutes: Int?
    var timeZoneIdentifier: String?
    var startDate: Date?
    var endDate: Date?
}

struct ParsedCommand: Equatable {
    // Core fields (create and edit)
    var originalText: String
    var actionType: ActionType
    var title: String
    var notes: String?

    // Create-task fields
    var startDate: Date?
    var endDate: Date?
    var reminderDate: Date?
    var confidence: Double?
    var parserSource: ParserSource
    var languageCode: String?
    var recurrence: ParsedRecurrence? = nil
    var alertStyle: ReminderAlertStyle? = nil

    // Edit-command fields (nil for create commands)
    /// The time reference used to identify an existing task.
    var targetDate: Date? = nil
    /// The new scheduled time for rescheduleTask commands.
    var newScheduledDate: Date? = nil
    /// Text to append to an existing task's notes.
    var appendText: String? = nil
    /// New title for updateTaskTitle (LLM / backend `new_title`).
    var newTitle: String? = nil
    /// How the backend resolved the edit target.
    var targetReferenceType: TargetReferenceType? = nil
    /// Explicit task id target returned by the backend.
    var targetTaskID: UUID? = nil
    /// Recurrence mutation requested by an edit/follow-up command. Applied in Phase 2.
    var recurrenceUpdate: ParsedRecurrenceUpdate? = nil
    /// Lead-time minutes before scheduled_at for creates (0 = at time).
    var reminderOffsetMinutes: Int? = nil
}
