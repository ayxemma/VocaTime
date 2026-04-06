import Foundation

/// Lightweight adapter around `LocalTaskParser` / `IntentParserService` for fast, offline
/// transcript evaluation during routing.
///
/// Used by `VoiceCommandViewModel` to get a quick `ParsedCommand?` from the local recogniser
/// transcript *before* deciding whether to skip or invoke cloud transcription.
/// Never makes network requests.
struct LocalTranscriptEvaluator {

    private let localParser: any TaskParsing

    init(localParser: any TaskParsing = LocalTaskParser()) {
        self.localParser = localParser
    }

    /// Parses `transcript` using the rule-based local parser only.
    /// Returns `nil` if the transcript is empty or the parser throws.
    func evaluate(
        transcript: String,
        now: Date = .now,
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) async -> ParsedCommand? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return try? await localParser.parse(
            text: trimmed,
            now: now,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}
