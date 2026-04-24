import Foundation
import os.log

// MARK: - Parsing strategy

/// Controls which parser runs first and when the other is used as fallback.
///
/// - `llmFirst`:   Original behaviour — every transcript goes to the LLM; local parser is the
///                 fallback when LLM is unavailable or throws. Used on the cloud-fallback path
///                 where a network call has already been made and LLM accuracy is preferred.
///
/// - `localFirst`: New local-first behaviour — rule-based parser runs first; LLM is only called
///                 when the local result is clearly weak (actionType == .unknown with no date).
///                 Used on the fast local-transcript path to avoid an unnecessary network call.
enum ParsingStrategy {
    case llmFirst
    case localFirst
}

struct TaskParsingCoordinator {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TaskParsing")

    let localParser: any TaskParsing
    var llmParser: (any TaskParsing)?
    var strategy: ParsingStrategy = .localFirst

    init(
        localParser: any TaskParsing = LocalTaskParser(),
        llmParser: (any TaskParsing)? = nil,
        strategy: ParsingStrategy = .localFirst
    ) {
        self.localParser = localParser
        self.llmParser = llmParser
        self.strategy = strategy
    }

    func parse(
        text: String,
        now: Date,
        localeIdentifier: String,
        timeZoneIdentifier: String,
        activeTaskContext: ChatActiveTaskContext? = nil
    ) async -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.isEmpty ? text : trimmed

        Self.logLongString(prefix: "[TaskParsing] rawTranscript", text: text)
        Self.logLongString(prefix: "[TaskParsing] normalizedInput", text: input)
        Self.log.info("[TaskParsing] strategy=\(String(describing: self.strategy), privacy: .public)")

        guard !input.isEmpty else {
            Self.log.warning("[TaskParsing] empty input — fallback unknown")
            return Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        }

        // Chat follow-ups: disambiguation lives on the backend — skip local-first when we have active task context.
        if activeTaskContext != nil {
            Self.log.info("[TaskParsing] activeTaskContext set — using llmFirst for follow-up")
            return await parseLLMFirst(
                input: input, text: text, now: now,
                localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                activeTaskContext: activeTaskContext
            )
        }

        switch strategy {
        case .llmFirst:
            return await parseLLMFirst(
                input: input, text: text, now: now,
                localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                activeTaskContext: nil
            )
        case .localFirst:
            return await parseLocalFirst(
                input: input, text: text, now: now,
                localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier
            )
        }
    }

    // MARK: - LLM-first strategy (original behaviour — preserved for cloud-fallback path)

    private func parseLLMFirst(
        input: String, text: String, now: Date,
        localeIdentifier: String, timeZoneIdentifier: String,
        activeTaskContext: ChatActiveTaskContext?
    ) async -> ParsedCommand {
        // ── 1. LLM (primary) ─────────────────────────────────────────────────
        if let llm = llmParser {
            Self.log.info("[TaskParsing] llmFirst — llmParser called=true")
            do {
                let result = try await llm.parse(
                    text: input, now: now,
                    localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                    activeTaskContext: activeTaskContext
                )
                Self.log.info("[TaskParsing] llmParser succeeded=true")
                let final = Self.applyLLMShortInputOptionB(input: input, result: result)
                Self.logParsedCommand(final, label: "final (llm)")
                return final
            } catch {
                if let le = error as? LLMError {
                    Self.log.error("[TaskParsing] llmParser succeeded=false requestId=\(le.correlationRequestID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public) — falling back to localParser")
                } else {
                    Self.log.error("[TaskParsing] llmParser succeeded=false error=\(String(describing: error), privacy: .public) — falling back to localParser")
                }
            }
        } else {
            Self.log.warning("[TaskParsing] llmParser called=false (not configured) — falling back to localParser")
        }

        return await runLocalWithUnknownFallback(
            input: input, text: text, now: now,
            localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier
        )
    }

    // MARK: - Local-first strategy (new fast path)

    private func parseLocalFirst(
        input: String, text: String, now: Date,
        localeIdentifier: String, timeZoneIdentifier: String
    ) async -> ParsedCommand {
        // ── 1. Local parser (primary) ─────────────────────────────────────────
        Self.log.info("[TaskParsing] localFirst — localParser called=true")
        let localResult: ParsedCommand?
        do {
            localResult = try await localParser.parse(
                text: input, now: now,
                localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                activeTaskContext: nil
            )
        } catch {
            Self.log.error("[TaskParsing] localParser failed error=\(String(describing: error), privacy: .public)")
            localResult = nil
        }

        // If the local parser produced structured output (not a bare .unknown with no date),
        // return it immediately — no network call needed.
        if let local = localResult, !isWeakLocalResult(local) {
            Self.log.info("[TaskParsing] localParser result accepted actionType=\(String(describing: local.actionType), privacy: .public)")
            Self.logParsedCommand(local, label: "final (local)")
            return local
        }

        // ── 2. LLM fallback (only for weak or missing local result) ───────────
        if let llm = llmParser {
            Self.log.info("[TaskParsing] localFirst — localResult weak, trying llmParser")
            do {
                let result = try await llm.parse(
                    text: input, now: now,
                    localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                    activeTaskContext: nil
                )
                Self.log.info("[TaskParsing] llmParser fallbackSucceeded=true")
                let final = Self.applyLLMShortInputOptionB(input: input, result: result)
                Self.logParsedCommand(final, label: "final (llm fallback)")
                return final
            } catch {
                if let le = error as? LLMError {
                    Self.log.error("[TaskParsing] llmParser fallbackSucceeded=false requestId=\(le.correlationRequestID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                } else {
                    Self.log.error("[TaskParsing] llmParser fallbackSucceeded=false error=\(String(describing: error), privacy: .public)")
                }
            }
        }

        // ── 3. Return weak local result if we have one, else unknown fallback ─
        if let local = localResult {
            Self.logParsedCommand(local, label: "final (local weak, no llm)")
            return local
        }

        let fallback = Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        Self.logParsedCommand(fallback, label: "final (unknown fallback)")
        return fallback
    }

    // MARK: - Shared local + unknown fallback

    private func runLocalWithUnknownFallback(
        input: String, text: String, now: Date,
        localeIdentifier: String, timeZoneIdentifier: String
    ) async -> ParsedCommand {
        Self.log.info("[TaskParsing] localParser fallbackCalled=true")
        do {
            let local = try await localParser.parse(
                text: input, now: now,
                localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier,
                activeTaskContext: nil
            )
            Self.log.info("[TaskParsing] localParser fallbackSucceeded=true actionType=\(String(describing: local.actionType), privacy: .public)")
            Self.logParsedCommand(local, label: "final (local fallback)")
            return local
        } catch {
            Self.log.error("[TaskParsing] localParser fallbackSucceeded=false error=\(String(describing: error), privacy: .public)")
        }

        let fallback = Self.fallbackUnknown(text: text, localeIdentifier: localeIdentifier)
        Self.logParsedCommand(fallback, label: "final (unknown fallback)")
        return fallback
    }

    // MARK: - Helpers

    /// Option B: single-pass LLM result unchanged for scheduling; for short inputs, preserve
    /// the backend title when present and only clear notes / fallback title presentation.
    private static func applyLLMShortInputOptionB(input: String, result: ParsedCommand) -> ParsedCommand {
        let outcome = ShortInputLLMPresentation.applyOptionB(userInput: input, command: result)
        let out = outcome.command
        log.info("""
            [TaskParsing] titlePostProcess \
            backendTitle=\(outcome.backendTitle, privacy: .public) \
            rawTranscript=\(outcome.rawTranscript, privacy: .public) \
            finalTitle=\(outcome.finalTitle, privacy: .public) \
            shortInput=\(outcome.isShortInput, privacy: .public) \
            titleModified=\(outcome.didModifyTitle, privacy: .public) \
            reason=\(outcome.reason, privacy: .public)
            """)
        if out.notes != result.notes {
            log.info("[TaskParsing] shortInput Option B — notes presentation adjusted (llm) title=\(out.title, privacy: .public)")
        }
        return out
    }

    /// A "weak" local result is one where the parser returned `.unknown` with no date information.
    /// These are prime candidates for LLM improvement.
    private func isWeakLocalResult(_ command: ParsedCommand) -> Bool {
        command.actionType == .unknown
            && command.startDate == nil
            && command.reminderDate == nil
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
