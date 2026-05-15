import Foundation

struct LLMTaskParseResponse: Decodable {
    struct Recurrence: Decodable {
        let frequency: String?
        let weekdays: [Int]?
        let time: String?
        let timezone: String?
        let startDate: String?
        let endDate: String?

        enum CodingKeys: String, CodingKey {
            case frequency, weekdays, time, timezone
            case startDate = "start_date"
            case endDate = "end_date"
        }
    }

    struct RecurrenceUpdate: Decodable {
        let operation: String?
        let weekdays: [Int]?
        let time: String?
        let timezone: String?
        let startDate: String?
        let endDate: String?

        enum CodingKeys: String, CodingKey {
            case operation, weekdays, time, timezone
            case startDate = "start_date"
            case endDate = "end_date"
        }
    }

    // ── Create-task fields ────────────────────────────────────
    let title: String?
    let notes: String?
    let actionType: String?
    let scheduledAt: String?
    let endAt: String?
    let hasSpecificTime: Bool?
    let languageCode: String?
    let confidence: Double?
    let recurrence: Recurrence?

    // ── Edit-command fields ───────────────────────────────────
    /// ISO8601 time reference for the existing task to act on.
    let targetTime: String?
    /// ISO8601 new scheduled time (rescheduleTask only).
    let newScheduledAt: String?
    /// Text to append to the existing task's notes (appendToTask only).
    let appendText: String?
    /// New title (updateTaskTitle only).
    let newTitle: String?
    /// Edit target reference source: task_id, recent_task, time, title, or null.
    let targetReferenceType: String?
    /// Explicit task UUID when targetReferenceType is task_id or recent_task.
    let targetTaskID: String?
    /// Structured recurrence mutation for updateRecurrence commands.
    let recurrenceUpdate: RecurrenceUpdate?

    enum CodingKeys: String, CodingKey {
        case title, notes, confidence
        case actionType     = "action_type"
        case scheduledAt    = "scheduled_at"
        case endAt          = "end_at"
        case hasSpecificTime = "has_specific_time"
        case languageCode   = "language_code"
        case recurrence
        case targetTime     = "target_time"
        case newScheduledAt = "new_scheduled_at"
        case appendText     = "append_text"
        case newTitle       = "new_title"
        case targetReferenceType = "target_reference_type"
        case targetTaskID    = "target_task_id"
        case recurrenceUpdate = "recurrence_update"
    }
}
