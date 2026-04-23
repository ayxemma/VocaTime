import Foundation
import os.log

enum LLMError: Error {
    case invalidResponse(requestId: UUID)
    case decodingFailed(requestId: UUID)
    case networkError(underlying: Error, requestId: UUID)
}

extension LLMError {
    var correlationRequestID: UUID {
        switch self {
        case .invalidResponse(let id): return id
        case .decodingFailed(let id): return id
        case .networkError(_, let id): return id
        }
    }
}

/// Parses natural-language task commands via the ChatTask backend `POST /parse` endpoint.
/// The server returns JSON decodable as `LLMTaskParseResponse` (stable app contract; not exposed to views).
struct LLMTaskParserService: TaskParsing {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TaskParsing")

    func parse(text: String, now: Date, localeIdentifier: String, timeZoneIdentifier: String) async throws -> ParsedCommand {
        BackendWarmup.scheduleSessionWarmup() // same session API as app lifecycle; coalesced
        let requestId = UUID()
        let endpoint = BackendConfig.parseURL
        Self.log.info("[Parse] requestId=\(requestId.uuidString, privacy: .public) requestStart backendBaseURL=\(BackendConfig.baseURL.absoluteString, privacy: .public)")

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let nowString = formatter.string(from: now)

        // Contract matches backend `ParseRequest` / `LLMTaskParseResponse` (snake_case). Parsing rules live on the server only.
        let requestBody: [String: Any] = [
            BackendCorrelation.requestIDJSONKey: requestId.uuidString,
            "text": text,
            "now": nowString,
            "timezone": timeZoneIdentifier,
            "locale": localeIdentifier,
        ]

        Self.log.info("[Parse] requestId=\(requestId.uuidString, privacy: .public) bodyReady textLength=\(text.count, privacy: .public) timezone=\(timeZoneIdentifier, privacy: .public)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(requestId.uuidString, forHTTPHeaderField: BackendCorrelation.requestIDHeaderField)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            // `POST /parse` is not assumed idempotent: retry only transport `URLError`s, not 502/503 bodies.
            (data, response) = try await BackendFetchRetry.data(for: request, isIdempotent: false)
        } catch {
            Self.log.error("[Parse] requestId=\(requestId.uuidString, privacy: .public) requestFailed rootCause=networkError error=\(String(describing: error), privacy: .public)")
            if let urlError = error as? URLError {
                Self.log.error("[Parse] requestId=\(requestId.uuidString, privacy: .public) urlError code=\(urlError.code.rawValue, privacy: .public) — connection refused often means backend not running or wrong CHATTASK_BACKEND_URL / default base URL")
            }
            throw LLMError.networkError(underlying: error, requestId: requestId)
        }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        Self.log.info("[Parse] requestId=\(requestId.uuidString, privacy: .public) httpStatusCode=\(statusCode, privacy: .public) responseBytes=\(data.count, privacy: .public)")

        let rawResponseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        Self.logLongString(prefix: "[Parse] rawHttpResponseBody requestId=\(requestId.uuidString)", text: rawResponseBody)

        if let http, !(200...299).contains(http.statusCode) {
            Self.log.error("[Parse] requestId=\(requestId.uuidString, privacy: .public) requestFailed rootCause=httpError httpStatusCode=\(statusCode, privacy: .public) — see raw body logs above")
            throw LLMError.invalidResponse(requestId: requestId)
        }

        let parsed: LLMTaskParseResponse
        do {
            parsed = try JSONDecoder().decode(LLMTaskParseResponse.self, from: data)
        } catch {
            Self.log.error("[Parse] requestId=\(requestId.uuidString, privacy: .public) requestFailed rootCause=invalidJSON decodeError=\(String(describing: error), privacy: .public)")
            throw LLMError.decodingFailed(requestId: requestId)
        }

        Self.log.info("[Parse] requestId=\(requestId.uuidString, privacy: .public) requestSucceeded")
        Self.logDecodedResponse(parsed)

        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let (actionType, actionTypeUnmapped) = Self.mapLLMActionType(parsed.actionType)
        if actionTypeUnmapped {
            Self.log.warning("[Parse] action_type unmapped raw=\(parsed.actionType ?? "nil", privacy: .public)")
        }

        if actionType == .deleteTask || actionType == .rescheduleTask || actionType == .appendToTask {
            let targetDate = parsed.targetTime.flatMap { Self.parseISO8601($0, timeZone: tz) }
            let newScheduledDate = parsed.newScheduledAt.flatMap { Self.parseISO8601($0, timeZone: tz) }

            let cmd = ParsedCommand(
                originalText: text,
                actionType: actionType,
                title: parsed.title ?? "",
                notes: nil,
                startDate: nil,
                endDate: nil,
                reminderDate: nil,
                confidence: parsed.confidence,
                parserSource: .llm,
                languageCode: parsed.languageCode,
                targetDate: targetDate,
                newScheduledDate: newScheduledDate,
                appendText: parsed.appendText
            )
            Self.logFinalParsedCommand(cmd)
            return cmd
        }

        var scheduledDate: Date?
        if let dateString = parsed.scheduledAt {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                scheduledDate = Self.parseISO8601(trimmed, timeZone: tz)
                if scheduledDate == nil {
                    Self.log.warning("[Parse] scheduled_at unparseable raw=\(dateString, privacy: .public)")
                }
            }
        }

        var endDate: Date?
        if let dateString = parsed.endAt {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                endDate = Self.parseISO8601(trimmed, timeZone: tz)
                if endDate == nil {
                    Self.log.warning("[Parse] end_at unparseable raw=\(dateString, privacy: .public)")
                }
            }
        }

        let cmd = ParsedCommand(
            originalText: text,
            actionType: actionType,
            title: parsed.title ?? text,
            notes: parsed.notes,
            startDate: actionType == .calendarEvent ? scheduledDate : nil,
            endDate: endDate,
            reminderDate: actionType == .reminder ? scheduledDate : nil,
            confidence: parsed.confidence,
            parserSource: .llm,
            languageCode: parsed.languageCode
        )

        Self.logFinalParsedCommand(cmd)
        return cmd
    }

    // MARK: - Logging helpers

    private static func logDecodedResponse(_ p: LLMTaskParseResponse) {
        log.info("""
            [Parse] decoded response action_type=\(p.actionType ?? "nil", privacy: .public) \
            title=\(p.title ?? "nil", privacy: .public) \
            scheduled_at=\(p.scheduledAt ?? "nil", privacy: .public) \
            target_time=\(p.targetTime ?? "nil", privacy: .public) \
            new_scheduled_at=\(p.newScheduledAt ?? "nil", privacy: .public) \
            append_text=\(p.appendText ?? "nil", privacy: .public)
            """)
    }

    private static func logFinalParsedCommand(_ cmd: ParsedCommand) {
        let start = cmd.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let reminder = cmd.reminderDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let target = cmd.targetDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let newSched = cmd.newScheduledDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        log.info("[Parse] final ParsedCommand actionType=\(String(describing: cmd.actionType), privacy: .public) title=\(cmd.title, privacy: .public) startDate=\(start, privacy: .public) reminderDate=\(reminder, privacy: .public) targetDate=\(target, privacy: .public) newScheduledDate=\(newSched, privacy: .public)")
    }

    private static func logLongString(prefix: String, text: String, chunkSize: Int = 800) {
        if text.count <= chunkSize {
            log.info("\(prefix, privacy: .public)=\(text, privacy: .public)")
            return
        }
        var startIndex = text.startIndex
        var part = 1
        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let slice = String(text[startIndex..<endIndex])
            log.info("\(prefix, privacy: .public) part\(part, privacy: .public)=\(slice, privacy: .public)")
            startIndex = endIndex
            part += 1
        }
    }

    // MARK: - Mapping helpers

    private static func mapLLMActionType(_ raw: String?) -> (ActionType, unmapped: Bool) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (.unknown, false)
        }
        let collapsed = raw.replacingOccurrences(of: "_", with: "").lowercased()
        switch collapsed {
        case "reminder":       return (.reminder, false)
        case "calendarevent":  return (.calendarEvent, false)
        case "unknown":        return (.unknown, false)
        case "deletetask":     return (.deleteTask, false)
        case "rescheduletask": return (.rescheduleTask, false)
        case "appendtotask":   return (.appendToTask, false)
        default:
            if let t = ActionType(rawValue: raw) { return (t, false) }
            return (.unknown, true)
        }
    }

    private static func parseISO8601(_ string: String, timeZone: TimeZone) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let f1 = ISO8601DateFormatter()
        f1.timeZone = timeZone
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: trimmed) { return d }

        let f2 = ISO8601DateFormatter()
        f2.timeZone = timeZone
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: trimmed) { return d }

        let f3 = ISO8601DateFormatter()
        f3.timeZone = timeZone
        f3.formatOptions = [.withFullDate]
        if let d = f3.date(from: trimmed) { return d }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.calendar = calendar
            df.timeZone = timeZone
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = pattern
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }
}
