import Foundation
import os.log

struct CommandInterpretTaskSnapshot: Codable {
    let id: String
    let title: String
    let scheduledAt: String?
    let isRecurring: Bool
    let recurrenceLabel: String?
    let notesSnippet: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case scheduledAt = "scheduled_at"
        case isRecurring = "is_recurring"
        case recurrenceLabel = "recurrence_label"
        case notesSnippet = "notes_snippet"
    }
}

struct CommandInterpretRequest: Encodable {
    let text: String
    let now: String
    let timezone: String
    let locale: String?
    let activeTask: CommandInterpretTaskSnapshot?
    let candidateTasks: [CommandInterpretTaskSnapshot]
    let requestID: String
    let commandSessionID: String?

    enum CodingKeys: String, CodingKey {
        case text, now, timezone, locale
        case activeTask = "active_task"
        case candidateTasks = "candidate_tasks"
        case requestID = "request_id"
        case commandSessionID = "command_session_id"
    }
}

struct CommandInterpretResponse: Decodable {
    struct Target: Decodable {
        let resolution: String?
        let selectedTaskID: String?
        let selectedTaskTitle: String?
        let candidateIDs: [String]?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case resolution, reason
            case selectedTaskID = "selected_task_id"
            case selectedTaskTitle = "selected_task_title"
            case candidateIDs = "candidate_ids"
        }
    }

    struct Create: Decodable {
        let title: String?
        let notes: String?
        let scheduledAt: String?
        let endAt: String?
        let hasSpecificTime: Bool?
        let recurrenceType: String?
        let recurrenceWeekdays: [Int]?
        let recurrenceEndAt: String?
        let alertStyle: String?
        let reminderOffsetMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case title, notes
            case scheduledAt = "scheduled_at"
            case endAt = "end_at"
            case hasSpecificTime = "has_specific_time"
            case recurrenceType = "recurrence_type"
            case recurrenceWeekdays = "recurrence_weekdays"
            case recurrenceEndAt = "recurrence_end_at"
            case alertStyle = "alert_style"
            case reminderOffsetMinutes = "reminder_offset_minutes"
        }
    }

    struct Edit: Decodable {
        let newTitle: String?
        let newScheduledAt: String?
        let appendText: String?
        let newRecurrenceType: String?
        let newRecurrenceWeekdays: [Int]?
        let alertStyle: String?
        let applyScope: String?
        let reminderOffsetMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case newTitle = "new_title"
            case newScheduledAt = "new_scheduled_at"
            case appendText = "append_text"
            case newRecurrenceType = "new_recurrence_type"
            case newRecurrenceWeekdays = "new_recurrence_weekdays"
            case alertStyle = "alert_style"
            case applyScope = "apply_scope"
            case reminderOffsetMinutes = "reminder_offset_minutes"
        }
    }

    struct Action: Decodable {
        let actionType: String?
        let confidence: Double
        let requiresConfirmation: Bool
        let confirmationKind: String?
        let assistantMessage: String?
        let target: Target?
        let create: Create?
        let edit: Edit?

        enum CodingKeys: String, CodingKey {
            case actionType = "action_type"
            case confidence
            case requiresConfirmation = "requires_confirmation"
            case confirmationKind = "confirmation_kind"
            case assistantMessage = "assistant_message"
            case target, create, edit
        }
    }

    let actions: [Action]?
    let actionType: String?
    let confidence: Double
    let requiresConfirmation: Bool
    let confirmationKind: String?
    let assistantMessage: String?
    let target: Target?
    let create: Create?
    let edit: Edit?

    enum CodingKeys: String, CodingKey {
        case actions
        case actionType = "action_type"
        case confidence
        case requiresConfirmation = "requires_confirmation"
        case confirmationKind = "confirmation_kind"
        case assistantMessage = "assistant_message"
        case target, create, edit
    }

    var multiActions: [Action] {
        guard let actions, !actions.isEmpty else { return [] }
        return actions
    }
}

extension CommandInterpretResponse {
    init(action: Action, assistantMessage overallMessage: String?) {
        self.actions = nil
        self.actionType = action.actionType
        self.confidence = action.confidence
        self.requiresConfirmation = action.requiresConfirmation
        self.confirmationKind = action.confirmationKind
        self.assistantMessage = action.assistantMessage ?? overallMessage
        self.target = action.target
        self.create = action.create
        self.edit = action.edit
    }
}

struct CommandInterpreterService {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "CommandInterpreter")

    func interpret(_ body: CommandInterpretRequest) async throws -> CommandInterpretResponse {
        let interpretT0 = CFAbsoluteTimeGetCurrent()
        await VoiceCommandLatencyTrace.recordInterpretBackendCall()
        await VoiceCommandLatencyTrace.markInterpretRequestStart()

        var request = URLRequest(url: BackendConfig.interpretCommandURL)
        request.httpMethod = "POST"
        let commandSessionId = await VoiceCommandLatencyTrace.active?.sessionTag
        BackendCorrelation.applyTracingHeaders(
            to: &request,
            requestId: UUID(uuidString: body.requestID) ?? UUID(),
            commandSessionId: commandSessionId
        )
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 90

        let payloadBytes = request.httpBody?.count ?? 0
        Self.log.info("[CommandInterpreter] commandInterpretStart requestId=\(body.requestID, privacy: .public) commandSessionId=\(body.commandSessionID ?? "none", privacy: .public) candidateTasksBuilt count=\(body.candidateTasks.count, privacy: .public) requestBodyBytes=\(payloadBytes, privacy: .public)")
        let (data, response) = try await BackendFetchRetry.data(for: request, isIdempotent: false)
        let interpretMs = Int((CFAbsoluteTimeGetCurrent() - interpretT0) * 1000)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Self.log.error("[CommandInterpreter] requestFailed status=\(statusCode, privacy: .public) body=\(bodyText.prefix(300), privacy: .public)")
            throw LLMError.invalidResponse(requestId: UUID(uuidString: body.requestID) ?? UUID())
        }
        let decoded = try JSONDecoder().decode(CommandInterpretResponse.self, from: data)
        await VoiceCommandLatencyTrace.markInterpretSucceeded()
        await VoiceCommandLatencyTrace.markInterpretRequestComplete(
            responseBytes: data.count,
            actionsCount: decoded.actions?.count ?? (decoded.actionType != nil ? 1 : 0),
            durationMs: interpretMs
        )
        Self.log.info("[CommandInterpreter] commandInterpretResult action=\(decoded.actionType ?? "nil", privacy: .public) confidence=\(decoded.confidence, privacy: .public) confirmation=\(decoded.confirmationKind ?? "nil", privacy: .public) actionsCount=\(decoded.actions?.count ?? 0, privacy: .public) interpretRequestMs=\(interpretMs, privacy: .public)")
        return decoded
    }
}
