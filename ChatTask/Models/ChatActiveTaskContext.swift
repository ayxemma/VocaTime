import Foundation

/// Short-lived task snapshot for chat follow-ups while the sheet is open. Sent to `POST /parse` only.
struct ChatActiveTaskContext: Equatable, Sendable {
    var taskID: UUID
    var title: String
    var scheduledDate: Date?
    var notes: String?
    var recurrenceFrequency: RecurrenceFrequency?
    /// ISO weekdays: Monday = 1 ... Sunday = 7.
    var recurrenceWeekdays: [Int]
    var recurrenceTimeMinutes: Int?
    var recurrenceTimeZoneIdentifier: String?
}
