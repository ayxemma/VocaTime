import Foundation
import os.log

/// LLM-first parsing: every transcript goes to the LLM first.
/// Local parser is the fallback when LLM is unavailable or throws.
struct TaskParsingCoordinator {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TaskParsing")

    let localParser: any TaskParsing
    var llmParser: (any TaskParsing)?

    init(localParser: any TaskParsing = LocalTaskParser(), llmParser: (any TaskParsing)? = nil) {
        self.localParser = localParser
        self.llmParser = llmParser
    }

    func parse(
        text: String,
        now: Date,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) async -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.isEmpty ? text : trimmed

        Self.logLongString(prefix: "[TaskParsing] rawTranscript", text: text)
        Self.logLongString(prefix: "[TaskParsing] normalizedInput", text: input)
        Self.log.info("[TaskParsing] strategy=llmFirst")

        if input.isEmpty {
            Self.log.warning("[TaskParsing] empty input — fallback unknown")
            return Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        }

        // ── 1. LLM (primary) ─────────────────────────────────────────────────
        if let llm = llmParser {
            Self.log.info("[TaskParsing] llmParser called=true")
            do {
                let result = try await llm.parse(
                    text: input,
                    now: now,
                    localeIdentifier: localeIdentifier,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                Self.log.info("[TaskParsing] llmParser succeeded=true")
                Self.logParsedCommand(result, label: "final (llm)")
                return result
            } catch {
                Self.log.error("[TaskParsing] llmParser succeeded=false error=\(String(describing: error), privacy: .public) — falling back to localParser")
            }
        } else {
            Self.log.warning("[TaskParsing] llmParser called=false (not configured) — falling back to localParser")
        }

        // ── 2. Local parser (fallback) ────────────────────────────────────────
        Self.log.info("[TaskParsing] localParser fallbackCalled=true")
        do {
            let local = try await localParser.parse(
                text: input,
                now: now,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            )
            Self.log.info("[TaskParsing] localParser fallbackSucceeded=true actionType=\(String(describing: local.actionType), privacy: .public)")
            Self.logParsedCommand(local, label: "final (local fallback)")
            return local
        } catch {
            Self.log.error("[TaskParsing] localParser fallbackSucceeded=false error=\(String(describing: error), privacy: .public)")
        }

        // ── 3. Unknown fallback ───────────────────────────────────────────────
        let fallback = Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        Self.logParsedCommand(fallback, label: "final (unknown fallback)")
        return fallback
    }

    // MARK: - Helpers

    private static func logParsedCommand(_ cmd: ParsedCommand, label: String) {
        let start = cmd.startDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let reminder = cmd.reminderDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        log.info("[TaskParsing] \(label, privacy: .public) actionType=\(String(describing: cmd.actionType), privacy: .public) title=\(cmd.title, privacy: .public) startDate=\(start, privacy: .public) reminderDate=\(reminder, privacy: .public) parserSource=\(String(describing: cmd.parserSource), privacy: .public)")
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

    private static func fallbackUnknown(text: String, localeIdentifier: String) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled" : trimmed
        let languageCode = localeIdentifier.split(separator: "-").first.map(String.init)
        return ParsedCommand(
            originalText: text,
            actionType: .unknown,
            title: title,
            notes: nil,
            startDate: nil,
            endDate: nil,
            reminderDate: nil,
            confidence: nil,
            parserSource: .unknown,
            languageCode: languageCode
        )
    }
}
