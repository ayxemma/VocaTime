import Foundation
import os.log

struct TaskTargetResolveCandidate: Encodable {
    let id: String
    let title: String
    let scheduledAt: String?
    let isRecurring: Bool
    let recurrenceLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case scheduledAt = "scheduled_at"
        case isRecurring = "is_recurring"
        case recurrenceLabel = "recurrence_label"
    }
}

struct TaskTargetResolveRequest: Encodable {
    let userText: String
    let actionType: String
    let targetTitle: String?
    let targetTime: String?
    let candidates: [TaskTargetResolveCandidate]
    let activeTaskID: String?
    let timezone: String
    let locale: String?

    enum CodingKeys: String, CodingKey {
        case userText = "user_text"
        case actionType = "action_type"
        case targetTitle = "target_title"
        case targetTime = "target_time"
        case candidates
        case activeTaskID = "active_task_id"
        case timezone
        case locale
    }
}

struct TaskTargetResolveResponse: Decodable {
    enum Resolution: String, Decodable {
        case resolved
        case needsConfirmation = "needs_confirmation"
        case ambiguous
        case noMatch = "no_match"
    }

    let resolution: Resolution
    let selectedID: String?
    let confidence: Double
    let reason: String?
    let candidates: [String]?

    enum CodingKeys: String, CodingKey {
        case resolution
        case selectedID = "selected_id"
        case confidence
        case reason
        case candidates
    }
}

struct TaskTargetResolverService {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TaskResolver")

    func resolve(_ requestBody: TaskTargetResolveRequest) async throws -> TaskTargetResolveResponse {
        let requestId = UUID()
        var request = URLRequest(url: BackendConfig.resolveTaskTargetURL)
        request.httpMethod = "POST"
        request.setValue(requestId.uuidString, forHTTPHeaderField: BackendCorrelation.requestIDHeaderField)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 60

        Self.log.info("[TaskResolver] resolveTaskTargetRequest requestId=\(requestId.uuidString, privacy: .public) candidateCount=\(requestBody.candidates.count, privacy: .public)")
        let (data, response) = try await BackendFetchRetry.data(for: request, isIdempotent: false)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Self.log.error("[TaskResolver] requestFailed status=\(statusCode, privacy: .public) body=\(body.prefix(300), privacy: .public)")
            throw LLMError.invalidResponse(requestId: requestId)
        }

        let decoded = try JSONDecoder().decode(TaskTargetResolveResponse.self, from: data)
        Self.log.info("[TaskResolver] resolverDecision=\(decoded.resolution.rawValue, privacy: .public) resolverSelected id=\(decoded.selectedID ?? "nil", privacy: .public) confidence=\(decoded.confidence, privacy: .public) resolverReason=\(decoded.reason ?? "nil", privacy: .public)")
        return decoded
    }
}
