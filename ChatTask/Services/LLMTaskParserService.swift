// OpenAI API key lives in `Secrets.swift` (gitignored). Copy `Secrets.swift.example` → `Secrets.swift` if missing.

import Foundation
import os.log

enum LLMError: Error {
    case invalidResponse
    case decodingFailed
}

struct LLMTaskParserService: TaskParsing {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TaskParsing")

    private var apiKey: String { Secrets.openAIAPIKey }
    private let endpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    func parse(text: String, now: Date, localeIdentifier: String, timeZoneIdentifier: String) async throws -> ParsedCommand {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let nowString = formatter.string(from: now)

        let systemPrompt = """
        You are a highly capable multilingual task assistant.
        The user speaks commands in English, Chinese, Spanish, or a mixture.
        Understand the intent, and return ONLY a valid JSON object — no markdown, no extra text.

        Current Date/Time: \(nowString)
        Timezone: \(timeZoneIdentifier)

        Determine the action_type:
        - "reminder"      — create a reminder task ("remind me to…", "remember to…")
        - "calendarEvent" — create a calendar/timed event
        - "unknown"       — create a task but time/type is unclear
        - "deleteTask"    — user wants to delete or cancel an existing task
        - "rescheduleTask"— user wants to move/change the time of an existing task
        - "appendToTask"  — user wants to add extra text/note to an existing task

        For CREATE commands (reminder / calendarEvent / unknown):
          - "title": the core task phrase, concise and natural. Strip filler like "remind me to" / "don't forget to". If the sentence is already short, put everything here.
          - "notes": ONLY populate when there is clearly extra supporting detail that would make the title too long or cluttered — otherwise null. Common triggers: "and also", "also", "顺便", "另外", multiple separate actions, or a long secondary clause.
          - "scheduled_at": ISO8601 datetime if a time is given, else null
          - "end_at": ISO8601 end time if given, else null
          - "has_specific_time": true if a clock time is mentioned
          - "target_time": null
          - "new_scheduled_at": null
          - "append_text": null

        Title/notes examples:
          "Call the doctor at 3 about Ari's vaccine records"
          → {"title":"Call the doctor about Ari's vaccine records","notes":null}

          "Remind me tomorrow at 5 to call the doctor about Ari's vaccine records and also ask whether the follow-up appointment should be next week"
          → {"title":"Call the doctor about Ari's vaccine records","notes":"Also ask whether the follow-up appointment should be next week"}

          "明天下午五点提醒我给医生打电话问Ari的疫苗记录，然后顺便确认下周要不要复诊"
          → {"title":"给医生打电话问Ari的疫苗记录","notes":"确认下周要不要复诊"}

        For EDIT commands (deleteTask / rescheduleTask / appendToTask):
          - "title": null (or the task title if the user mentions it by name)
          - "notes": null
          - "scheduled_at": null
          - "end_at": null
          - "has_specific_time": false
          - "target_time": ISO8601 datetime of the EXISTING task the user is referring to (required for all edit commands)
          - "new_scheduled_at": ISO8601 datetime of the new time (rescheduleTask only, else null)
          - "append_text": the text to add to the task (appendToTask only, else null)

        JSON schema:
        {
          "title": string | null,
          "notes": string | null,
          "action_type": "reminder" | "calendarEvent" | "unknown" | "deleteTask" | "rescheduleTask" | "appendToTask",
          "scheduled_at": string | null,
          "end_at": string | null,
          "has_specific_time": boolean,
          "language_code": "en" | "zh" | "es" | "mixed",
          "confidence": number,
          "target_time": string | null,
          "new_scheduled_at": string | null,
          "append_text": string | null
        }
        """

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.0
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        Self.log.info("[LLM] httpStatusCode=\(statusCode, privacy: .public)")

        let rawResponseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        Self.logLongString(prefix: "[LLM] rawHttpResponseBody", text: rawResponseBody)

        if let http, !(200...299).contains(http.statusCode) {
            Self.log.error("[LLM] request failed httpStatusCode=\(statusCode, privacy: .public)")
            throw LLMError.invalidResponse
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let apiResponse: OpenAIResponse
        do {
            apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            Self.log.error("[LLM] OpenAI envelope decode failed error=\(String(describing: error), privacy: .public)")
            throw LLMError.decodingFailed
        }

        guard let jsonString = apiResponse.choices.first?.message.content else {
            Self.log.error("[LLM] missing choices[0].message.content")
            throw LLMError.invalidResponse
        }

        Self.logLongString(prefix: "[LLM] modelMessageContentRaw", text: jsonString)

        guard let jsonData = jsonString.data(using: .utf8) else {
            Self.log.error("[LLM] model message content is not valid UTF-8")
            throw LLMError.invalidResponse
        }

        let parsed: LLMTaskParseResponse
        do {
            parsed = try JSONDecoder().decode(LLMTaskParseResponse.self, from: jsonData)
        } catch {
            Self.log.error("[LLM] LLMTaskParseResponse decode failed error=\(String(describing: error), privacy: .public)")
            throw LLMError.decodingFailed
        }

        Self.logDecodedLLMResponse(parsed)

        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let (actionType, actionTypeUnmapped) = Self.mapLLMActionType(parsed.actionType)
        if actionTypeUnmapped {
            Self.log.warning("[LLM] action_type unmapped raw=\(parsed.actionType ?? "nil", privacy: .public)")
        }

        // ── Edit command ──────────────────────────────────────────────────────
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

        // ── Create command ────────────────────────────────────────────────────
        var scheduledDate: Date?
        if let dateString = parsed.scheduledAt {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                scheduledDate = Self.parseISO8601(trimmed, timeZone: tz)
                if scheduledDate == nil {
                    Self.log.warning("[LLM] scheduled_at unparseable raw=\(dateString, privacy: .public)")
                }
            }
        }

        var endDate: Date?
        if let dateString = parsed.endAt {
            let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                endDate = Self.parseISO8601(trimmed, timeZone: tz)
                if endDate == nil {
                    Self.log.warning("[LLM] end_at unparseable raw=\(dateString, privacy: .public)")
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

    private static func logDecodedLLMResponse(_ p: LLMTaskParseResponse) {
        log.info("""
            [LLM] decoded response action_type=\(p.actionType ?? "nil", privacy: .public) \
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
        log.info("[LLM] final ParsedCommand actionType=\(String(describing: cmd.actionType), privacy: .public) title=\(cmd.title, privacy: .public) startDate=\(start, privacy: .public) reminderDate=\(reminder, privacy: .public) targetDate=\(target, privacy: .public) newScheduledDate=\(newSched, privacy: .public)")
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
