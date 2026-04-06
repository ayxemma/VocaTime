import Foundation
import os.log

// MARK: - Quality signal

/// Aggregates all signals used to decide whether a local Apple speech transcript is
/// trustworthy enough to skip the cloud (OpenAI) transcription fallback.
struct TranscriptionQualitySignal {
    let transcript: String
    let confidence: Float?
    let duration: TimeInterval
    /// Whether the local rule-based parser produced a usable command.
    let parseSucceeded: Bool
    let parsedCommand: ParsedCommand?
    let containsMixedLanguage: Bool
    let containsRareTerms: Bool
    /// True when heuristics suggest the transcript has a higher-than-normal error risk
    /// (e.g. garbled short result from a long utterance).
    let userCorrectionRisk: Bool
}

// MARK: - Routing decision

enum RoutingDecision {
    /// Use the trimmed local transcript directly — skip cloud transcription.
    case acceptLocalTranscript(String)
    /// Discard the local transcript and upload the audio to the cloud transcription API.
    case fallbackToCloud
}

// MARK: - Protocol (for testability)

protocol TranscriptionRouting {
    func evaluate(
        transcript: String,
        confidence: Float?,
        duration: TimeInterval,
        parsedCommand: ParsedCommand?
    ) -> RoutingDecision
}

// MARK: - Default implementation

/// Deterministic, synchronous quality router.
/// Runs on the critical path between `stopListening()` and parsing, so it must be fast (no I/O).
struct TranscriptionRouter: TranscriptionRouting {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "TranscriptionRouter")

    // MARK: - Thresholds

    /// Minimum Apple recognizer confidence to trust the transcript without cloud verification.
    static let confidenceThreshold: Float = 0.78
    /// If a recording is longer than this many seconds but the transcript is very short, the
    /// recognizer likely missed much of the utterance.
    static let longDurationThreshold: TimeInterval = 6.0
    /// Character count below which a transcript is considered "suspiciously short" relative to a
    /// long recording. Eight characters covers roughly one short word.
    static let shortTranscriptThreshold = 8

    // MARK: - Rare terms (configurable — inject user contacts or domain vocabulary here)

    /// Transcripts containing any of these strings trigger a cloud fallback to reduce the risk
    /// of misrecognised proper nouns. Compared case-insensitively.
    var rareTerms: [String] = []

    // MARK: - Evaluate

    func evaluate(
        transcript: String,
        confidence: Float?,
        duration: TimeInterval,
        parsedCommand: ParsedCommand?
    ) -> RoutingDecision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // ── 1. Empty transcript → always fall back ────────────────────────────
        guard !trimmed.isEmpty else {
            Self.log.info("[Router] decision=fallbackToCloud reason=emptyTranscript")
            return .fallbackToCloud
        }

        // ── 2. Long utterance but very short transcript → likely garbled ──────
        if duration > Self.longDurationThreshold, trimmed.count < Self.shortTranscriptThreshold {
            Self.log.info("[Router] decision=fallbackToCloud reason=longDurationShortTranscript duration=\(duration, privacy: .public)s chars=\(trimmed.count, privacy: .public)")
            return .fallbackToCloud
        }

        // ── 3. Low confidence from Apple recognizer ───────────────────────────
        if let c = confidence, c < Self.confidenceThreshold {
            Self.log.info("[Router] decision=fallbackToCloud reason=lowConfidence confidence=\(c, privacy: .public)")
            return .fallbackToCloud
        }

        // ── 4. Mixed Chinese + Latin script ──────────────────────────────────
        if detectMixedLanguage(trimmed) {
            Self.log.info("[Router] decision=fallbackToCloud reason=mixedLanguage")
            return .fallbackToCloud
        }

        // ── 5. Rare / proper-noun terms ───────────────────────────────────────
        if detectRareTerms(trimmed) {
            Self.log.info("[Router] decision=fallbackToCloud reason=rareTermDetected")
            return .fallbackToCloud
        }

        // ── 6. Null parse result (evaluator returned nothing) ─────────────────
        guard let parsedCommand else {
            Self.log.info("[Router] decision=fallbackToCloud reason=noParsedCommand")
            return .fallbackToCloud
        }

        // ── 7. Weak parse: unknown action + no extracted date + short transcript
        //      These are cases where the LLM is likely to produce a better result ─
        if isParseWeak(parsedCommand), trimmed.count < 20 {
            Self.log.info("[Router] decision=fallbackToCloud reason=weakParseShortTranscript actionType=\(String(describing: parsedCommand.actionType), privacy: .public)")
            return .fallbackToCloud
        }

        // ── Accept ────────────────────────────────────────────────────────────
        Self.log.info("[Router] decision=acceptLocalTranscript chars=\(trimmed.count, privacy: .public) confidence=\(String(describing: confidence), privacy: .public) actionType=\(String(describing: parsedCommand.actionType), privacy: .public)")
        return .acceptLocalTranscript(trimmed)
    }

    // MARK: - Language helpers

    /// Returns `true` when the text contains both CJK characters and basic Latin letters,
    /// which indicates a mixed-language utterance that Apple's recogniser may handle poorly.
    func detectMixedLanguage(_ text: String) -> Bool {
        var hasLatin = false
        var hasCJK = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { hasLatin = true }
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x20000...0x2A6DF).contains(v) { hasCJK = true }
            if hasLatin && hasCJK { return true }
        }
        return false
    }

    func detectRareTerms(_ text: String) -> Bool {
        guard !rareTerms.isEmpty else { return false }
        let lower = text.lowercased()
        return rareTerms.contains { lower.contains($0.lowercased()) }
    }

    // MARK: - Parse quality helper

    /// A parse is considered weak when the action type is `.unknown` and no date was extracted.
    /// These are tasks where the cloud LLM can often extract structure that the rule-based parser missed.
    private func isParseWeak(_ command: ParsedCommand) -> Bool {
        command.actionType == .unknown
            && command.startDate == nil
            && command.reminderDate == nil
    }
}
