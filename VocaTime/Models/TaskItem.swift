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

    var kind: TaskKind {
        TaskKind(rawValue: kindRaw) ?? .task
    }

    var source: TaskSource {
        TaskSource(rawValue: sourceRaw) ?? .voice
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
        kind: TaskKind = .task
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
    }

    @MainActor
    static func insertFromParsedCommand(_ command: ParsedCommand, context: ModelContext) {
        let kind: TaskKind
        switch command.actionType {
        case .reminder: kind = .reminder
        case .calendarEvent: kind = .event
        case .unknown: kind = .task
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
            kind: kind
        )
        context.insert(item)
        try? context.save()
    }
}
