// OpenAI API key lives in `Secrets.swift` (gitignored). Copy `Secrets.swift.example` → `Secrets.swift` if missing.

import Foundation

enum LLMError: Error {
    case invalidResponse
    case decodingFailed
}

struct LLMTaskParserService: TaskParsing {
    private var apiKey: String { Secrets.openAIAPIKey }
    private let endpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    func parse(text: String, now: Date, localeIdentifier: String, timeZoneIdentifier: String) async throws -> ParsedCommand {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let nowString = formatter.string(from: now)

        let systemPrompt = """
        You are a highly capable multilingual task parsing assistant.
        The user will provide a command which may be in English, Chinese, or a mixture of both.
        Understand the intent, translate or normalize the title to the primary language spoken, and extract the schedule.

        Current Date/Time: \(nowString)
        Timezone: \(timeZoneIdentifier)

        Return ONLY a valid JSON object matching this schema. Do not wrap it in markdown blocks.
        {
          "title": "The name of the task",
          "notes": "Any extra contextual details",
          "action_type": "reminder" | "calendarEvent" | "unknown",
          "scheduled_at": "ISO8601 formatted string if a specific date or time is mentioned, else null",
          "end_at": "ISO8601 formatted string if an end time is mentioned, else null",
          "has_specific_time": true if a specific clock time is mentioned (false if it's just a day/Anytime),
          "language_code": "en" | "zh" | "mixed",
          "confidence": 0.9
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
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
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
            throw LLMError.decodingFailed
        }

        guard let jsonString = apiResponse.choices.first?.message.content,
              let jsonData = jsonString.data(using: .utf8)
        else {
            throw LLMError.invalidResponse
        }

        let parsed: LLMTaskParseResponse
        do {
            parsed = try JSONDecoder().decode(LLMTaskParseResponse.self, from: jsonData)
        } catch {
            throw LLMError.decodingFailed
        }

        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var scheduledDate: Date?
        if let dateString = parsed.scheduledAt {
            scheduledDate = Self.parseISO8601(dateString, timeZone: tz)
        }
        var endDate: Date?
        if let dateString = parsed.endAt {
            endDate = Self.parseISO8601(dateString, timeZone: tz)
        }

        let actionType = ActionType(rawValue: parsed.actionType ?? "") ?? .unknown

        return ParsedCommand(
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
    }

    /// Parses ISO8601 strings from the model, with or without fractional seconds.
    private static func parseISO8601(_ string: String, timeZone: TimeZone) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.timeZone = timeZone
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: string) { return d }
        let f2 = ISO8601DateFormatter()
        f2.timeZone = timeZone
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: string)
    }
}
