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
}
