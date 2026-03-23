import Foundation

private func intentParseError(_ message: String) -> Error {
    NSError(domain: "VocaTimeIntent", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Rule-based, local-only parsing of voice transcripts into `ParsedCommand`.
struct IntentParserService {
    private let dateParser: DateParser

    init(calendar: Calendar = .current, referenceDate: Date = .now) {
        self.dateParser = DateParser(calendar: calendar, referenceDate: referenceDate)
    }

    func parse(_ originalText: String, languageCode: String? = nil) -> Result<ParsedCommand, Error> {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(intentParseError("Nothing to parse."))
        }

        let dateMatch = dateParser.firstMatch(in: trimmed)
        let title = buildTitle(from: trimmed, stripping: dateMatch?.range)
        let lower = trimmed.lowercased()

        let hasRemind = lower.range(of: #"\bremind(?:er)?\b"#, options: .regularExpression) != nil
            || lower.contains("remember to")

        let matchedSnippet: String = {
            guard let r = dateMatch?.range else { return "" }
            return String(trimmed[r])
        }()

        let isRelativeIn = isRelativeTimeMatch(snippet: matchedSnippet)

        let actionType: ActionType
        if hasRemind {
            actionType = .reminder
        } else if isRelativeIn {
            actionType = .reminder
        } else if dateMatch != nil {
            actionType = .calendarEvent
        } else if lower.range(of: #"\b(appointment|meeting|calendar|event)\b"#, options: .regularExpression) != nil {
            actionType = .calendarEvent
        } else {
            actionType = .unknown
        }

        let date = dateMatch?.date
        var startDate: Date?
        var reminderDate: Date?
        switch actionType {
        case .reminder:
            reminderDate = date
        case .calendarEvent:
            startDate = date
        case .unknown:
            break
        }

        let confidence: Double?
        if date != nil, !title.isEmpty {
            confidence = actionType == .unknown ? 0.45 : 0.88
        } else if !title.isEmpty {
            confidence = 0.35
        } else {
            confidence = 0.2
        }

        let command = ParsedCommand(
            originalText: trimmed,
            actionType: actionType,
            title: title.isEmpty ? trimmed : title,
            notes: nil,
            startDate: startDate,
            endDate: nil,
            reminderDate: reminderDate,
            confidence: confidence,
            parserSource: .local,
            languageCode: languageCode
        )

        return .success(command)
    }

    /// True when the date match is English `in … minutes/hours` (digits or words) or Chinese 分钟后 / 小时后.
    private func isRelativeTimeMatch(snippet: String) -> Bool {
        guard !snippet.isEmpty else { return false }
        if snippet.contains("分钟") || snippet.contains("小时") { return true }
        let low = snippet.lowercased()
        return low.range(of: #"\bin\s+.+?\s+(minutes?|hours?)\b"#, options: .regularExpression) != nil
    }

    private func buildTitle(from text: String, stripping range: Range<String.Index>?) -> String {
        var t = text
        if let range {
            t.removeSubrange(range)
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixPatterns = [
            #"(?i)^remind\s+me\s+in\s+(?:\d+|[a-z]+(?:[\s\-]+[a-z]+)?)\s+(?:minutes?|hours?)\s+to\s+"#,
            #"(?i)^remind\s+me\s+to\s+"#,
            #"(?i)^remind\s+me\s+"#,
            #"(?i)^reminder\s+to\s+"#,
            #"(?i)^remember\s+to\s+"#,
        ]

        for pattern in prefixPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = t as NSString
            let full = NSRange(location: 0, length: ns.length)
            t = regex.stringByReplacingMatches(in: t, options: [], range: full, withTemplate: "")
        }

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
