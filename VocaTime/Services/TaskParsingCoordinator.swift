import Foundation
import os.log

/// English (ASCII Latin letters only): local parser first, then LLM if needed.
/// Any non-ASCII letters, CJK, or uncertain (no letters) → skip local, LLM only.
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

        let routing = Self.routing(for: input)
        let useLocalParserFirst = routing == .englishLocalFirst

        Self.log.info("[TaskParsing] routingDecision=\(routing.logLabel, privacy: .public)")
        Self.log.info("[TaskParsing] detectedLanguageRoute=\(routing.detectedLabel, privacy: .public)")
        Self.logLongString(prefix: "[TaskParsing] rawTranscript", text: text)
        Self.logLongString(prefix: "[TaskParsing] normalizedInput", text: input)
        Self.log.info("[TaskParsing] localParserSkipped=\(!useLocalParserFirst, privacy: .public)")

        if input.isEmpty {
            Self.log.warning("[TaskParsing] empty input — fallback unknown")
            return Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        }

        if !useLocalParserFirst {
            return await parseNonEnglishPath(
                input: input,
                originalText: text,
                now: now,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }

        return await parseEnglishPath(
            input: input,
            originalText: text,
            now: now,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    // MARK: - Routing heuristic

    private enum Routing {
        /// Only ASCII A–Z / a–z among letter characters; digits/punctuation/spaces allowed.
        case englishLocalFirst
        /// CJK, accented Latin, non-Latin scripts, or no letters (uncertain → prefer LLM).
        case directLLM

        var logLabel: String {
            switch self {
            case .englishLocalFirst: return "englishLocalFirst"
            case .directLLM: return "directLLM_nonEnglishOrUncertain"
            }
        }

        var detectedLabel: String {
            switch self {
            case .englishLocalFirst: return "english_ascii_latin"
            case .directLLM: return "non_english_or_uncertain"
            }
        }
    }

    /// Lightweight, deterministic: English only if every letter is ASCII A–Z / a–z. Otherwise LLM (including uncertainty).
    private static func routing(for input: String) -> Routing {
        var sawLetter = false
        for ch in input {
            if ch.isWhitespace { continue }
            guard ch.isLetter else { continue }
            sawLetter = true
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                return .directLLM
            }
            let v = scalar.value
            let isAsciiLatin = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            if !isAsciiLatin { return .directLLM }
        }
        if !sawLetter { return .directLLM }
        return .englishLocalFirst
    }

    // MARK: - English: local first, then LLM if unknown

    private func parseEnglishPath(
        input: String,
        originalText: String,
        now: Date,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) async -> ParsedCommand {
        do {
            let local = try await localParser.parse(
                text: input,
                now: now,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            )
            Self.log.info("[TaskParsing] localParser actionType=\(String(describing: local.actionType), privacy: .public) title=\(local.title, privacy: .public) parserSource=\(String(describing: local.parserSource), privacy: .public)")

            if local.actionType != .unknown {
                Self.log.info("[TaskParsing] llmParser called=false (local parser matched)")
                Self.logParsedCommand(local, label: "final (local)")
                return local
            }

            guard let llm = llmParser else {
                Self.log.warning("[TaskParsing] llmParser called=false (not configured) — returning local unknown")
                Self.logParsedCommand(local, label: "final")
                return local
            }

            Self.log.info("[TaskParsing] llmParser called=true (after local unknown)")
            do {
                let llmResult = try await llm.parse(
                    text: input,
                    now: now,
                    localeIdentifier: localeIdentifier,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                Self.log.info("[TaskParsing] llmParser succeeded=true")
                Self.logParsedCommand(llmResult, label: "final (llm)")
                return llmResult
            } catch {
                Self.log.error("[TaskParsing] llmParser succeeded=false error=\(String(describing: error), privacy: .public)")
                Self.logParsedCommand(local, label: "final (fallback to local unknown)")
                return local
            }
        } catch {
            Self.log.error("[TaskParsing] localParser threw=\(String(describing: error), privacy: .public)")
            guard let llm = llmParser else {
                Self.log.warning("[TaskParsing] llmParser not configured after local error")
                return Self.fallbackUnknown(text: originalText, localeIdentifier: localeIdentifier)
            }
            Self.log.info("[TaskParsing] llmParser called=true (after local throw)")
            do {
                let llmResult = try await llm.parse(
                    text: input,
                    now: now,
                    localeIdentifier: localeIdentifier,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                Self.log.info("[TaskParsing] llmParser succeeded=true")
                Self.logParsedCommand(llmResult, label: "final (llm)")
                return llmResult
            } catch {
                Self.log.error("[TaskParsing] llmParser succeeded=false error=\(String(describing: error), privacy: .public)")
                let fallback = Self.fallbackUnknown(text: originalText, localeIdentifier: localeIdentifier)
                Self.logParsedCommand(fallback, label: "final (fallback)")
                return fallback
            }
        }
    }

    // MARK: - Non-English: LLM only

    private func parseNonEnglishPath(
        input: String,
        originalText: String,
        now: Date,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) async -> ParsedCommand {
        guard let llm = llmParser else {
            Self.log.warning("[TaskParsing] llmParser called=false (nil) non-English transcript — fallback unknown")
            let fallback = Self.fallbackUnknown(text: originalText, localeIdentifier: localeIdentifier)
            Self.logParsedCommand(fallback, label: "final")
            return fallback
        }

        Self.log.info("[TaskParsing] llmParser called=true (non-English direct)")
        do {
            let llmResult = try await llm.parse(
                text: input,
                now: now,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            )
            Self.log.info("[TaskParsing] llmParser succeeded=true")
            Self.logParsedCommand(llmResult, label: "final (llm)")
            return llmResult
        } catch {
            Self.log.error("[TaskParsing] llmParser succeeded=false error=\(String(describing: error), privacy: .public)")
            let fallback = Self.fallbackUnknown(text: originalText, localeIdentifier: localeIdentifier)
            Self.logParsedCommand(fallback, label: "final (fallback)")
            return fallback
        }
    }

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
