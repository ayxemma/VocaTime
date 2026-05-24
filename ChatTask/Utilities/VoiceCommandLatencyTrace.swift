import Foundation
import os.log

/// End-to-end latency tracing for one voice command (or voice draft → send flow).
/// Attach via ``VoiceCommandLatencyTrace/active`` before backend calls; all services read the same session id.
final class VoiceCommandLatencySession {
    let commandSessionId: UUID
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "VoiceLatency")

    private(set) var voiceStartedAt: CFAbsoluteTime?
    private(set) var userStoppedAt: CFAbsoluteTime?
    private(set) var transcriptDeliveredAt: CFAbsoluteTime?
    private(set) var interpretStartedAt: CFAbsoluteTime?
    private(set) var assistantDisplayedAt: CFAbsoluteTime?

    private(set) var transcribeBackendCalls = 0
    private(set) var interpretBackendCalls = 0
    private(set) var parseBackendCalls = 0
    private(set) var resolveBackendCalls = 0
    private(set) var interpretSucceeded = false

    var audioDurationSeconds: TimeInterval?
    var audioFileSizeBytes: Int?
    var transcriptLength: Int?

    init(commandSessionId: UUID = UUID()) {
        self.commandSessionId = commandSessionId
    }

    var sessionTag: String { commandSessionId.uuidString }

    // MARK: - Lifecycle markers

    func markVoiceCommandStarted(startReason: String) {
        voiceStartedAt = CFAbsoluteTimeGetCurrent()
        let tag = sessionTag
        log.info("[VoiceLatency] voiceCommandStarted commandSessionId=\(tag, privacy: .public) startReason=\(startReason, privacy: .public)")
    }

    func markUserStoppedSpeaking(reason: VoiceStopReason) {
        userStoppedAt = CFAbsoluteTimeGetCurrent()
        let event: String = switch reason {
        case .manual: "manualStop"
        case .autoSilence: "autoSilenceStop"
        case .maxTimeout: "maxTimeoutStop"
        }
        let tag = sessionTag
        log.info("[VoiceLatency] \(event, privacy: .public) commandSessionId=\(tag, privacy: .public)")
    }

    func markTranscriptDelivered(length: Int) {
        transcriptDeliveredAt = CFAbsoluteTimeGetCurrent()
        transcriptLength = length
        let tag = sessionTag
        let stopMs = msSinceStop
        log.info("[VoiceLatency] transcriptDeliveredToInputMs=\(stopMs, privacy: .public) transcriptLength=\(length, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        log.info("[VoiceLatency] totalFromStopToTranscriptMs=\(stopMs, privacy: .public) commandSessionId=\(tag, privacy: .public)")
    }

    func markInterpretRequestStart() {
        interpretStartedAt = CFAbsoluteTimeGetCurrent()
        let tag = sessionTag
        log.info("[VoiceLatency] interpretRequestStart commandSessionId=\(tag, privacy: .public)")
    }

    func markInterpretRequestComplete(responseBytes: Int, actionsCount: Int, durationMs: Int) {
        let tag = sessionTag
        log.info("[VoiceLatency] interpretRequestMs=\(durationMs, privacy: .public) interpretResponseBytes=\(responseBytes, privacy: .public) actionsCount=\(actionsCount, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        if let stopped = userStoppedAt {
            let fromStop = Int((CFAbsoluteTimeGetCurrent() - stopped) * 1000)
            log.info("[VoiceLatency] totalFromStopToInterpretDoneMs=\(fromStop, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func markActionExecutionComplete(durationMs: Int) {
        let tag = sessionTag
        log.info("[VoiceLatency] frontendActionExecutionMs=\(durationMs, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        if let delivered = transcriptDeliveredAt {
            let ms = Int((CFAbsoluteTimeGetCurrent() - delivered) * 1000)
            log.info("[VoiceLatency] totalFromTranscriptToTaskDoneMs=\(ms, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func markAssistantMessageDisplayed(streaming: Bool) {
        assistantDisplayedAt = CFAbsoluteTimeGetCurrent()
        let tag = sessionTag
        let stopMs = msSinceStopOrZero
        log.info("[VoiceLatency] assistantMessageDisplayedMs=\(stopMs, privacy: .public) streaming=\(streaming, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        log.info("[VoiceLatency] totalFromStopToAssistantReplyMs=\(stopMs, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        emitEndToEndSummary()
    }

    // MARK: - Backend call accounting

    func recordTranscribeBackendCall() {
        transcribeBackendCalls += 1
        if transcribeBackendCalls > 1 {
            let tag = sessionTag
            let count = transcribeBackendCalls
            log.warning("[VoiceLatency] duplicateBackendCallDetected endpoint=/transcribe count=\(count, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func recordInterpretBackendCall() {
        interpretBackendCalls += 1
        if interpretBackendCalls > 1 {
            let tag = sessionTag
            let count = interpretBackendCalls
            log.warning("[VoiceLatency] duplicateBackendCallDetected endpoint=/interpret-command count=\(count, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func recordParseBackendCall() {
        parseBackendCalls += 1
        let tag = sessionTag
        if parseBackendCalls > 1 {
            let count = parseBackendCalls
            log.warning("[VoiceLatency] duplicateBackendCallDetected endpoint=/parse count=\(count, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
        if interpretSucceeded {
            log.warning("[VoiceLatency] extraLLMCallDetected endpoint=/parse reason=interpretAlreadySucceeded commandSessionId=\(tag, privacy: .public)")
        }
    }

    func recordResolveBackendCall() {
        resolveBackendCalls += 1
        if resolveBackendCalls > 1 {
            let tag = sessionTag
            let count = resolveBackendCalls
            log.warning("[VoiceLatency] duplicateBackendCallDetected endpoint=/resolve-task-target count=\(count, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func markInterpretSucceeded() {
        interpretSucceeded = true
    }

    func logFallbackTriggered(reason: String) {
        let tag = sessionTag
        log.warning("[VoiceLatency] fallbackTriggered reason=\(reason, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        if interpretSucceeded {
            log.warning("[VoiceLatency] extraLLMCallDetected reason=\(reason, privacy: .public) commandSessionId=\(tag, privacy: .public)")
        }
    }

    func applyCorrelationHeaders(to request: inout URLRequest, requestId: UUID) {
        BackendCorrelation.applyTracingHeaders(to: &request, requestId: requestId, commandSessionId: sessionTag)
    }

    // MARK: - Summary

    private var msSinceStop: Int {
        guard let stopped = userStoppedAt else { return 0 }
        return Int((CFAbsoluteTimeGetCurrent() - stopped) * 1000)
    }

    private var msSinceStopOrZero: Int {
        guard let stopped = userStoppedAt else { return 0 }
        return Int((CFAbsoluteTimeGetCurrent() - stopped) * 1000)
    }

    private func emitEndToEndSummary() {
        let tag = sessionTag
        let audioSec = audioDurationSeconds ?? -1
        let fileBytes = audioFileSizeBytes ?? -1
        let transcribeCount = transcribeBackendCalls
        let interpretCount = interpretBackendCalls
        let parseCount = parseBackendCalls
        let resolveCount = resolveBackendCalls
        let stopToTranscript = transcriptDeliveredAt.flatMap { d in userStoppedAt.map { Int((d - $0) * 1000) } } ?? -1
        let stopToReply = msSinceStopOrZero
        log.info("""
            [VoiceLatency] sessionSummary commandSessionId=\(tag, privacy: .public) \
            audioDurationSec=\(audioSec, privacy: .public) \
            audioFileSizeBytes=\(fileBytes, privacy: .public) \
            transcribeCalls=\(transcribeCount, privacy: .public) \
            interpretCalls=\(interpretCount, privacy: .public) \
            parseCalls=\(parseCount, privacy: .public) \
            resolveCalls=\(resolveCount, privacy: .public) \
            totalFromStopToTranscriptMs=\(stopToTranscript, privacy: .public) \
            totalFromStopToAssistantReplyMs=\(stopToReply, privacy: .public)
            """)
    }
}

/// Holds the active voice-command trace for correlation across services in one MainActor turn.
@MainActor
enum VoiceCommandLatencyTrace {
    private(set) static var active: VoiceCommandLatencySession?

    static func beginVoiceSession(startReason: String) -> VoiceCommandLatencySession {
        let session = VoiceCommandLatencySession()
        active = session
        session.markVoiceCommandStarted(startReason: startReason)
        return session
    }

    static func beginTypedSession() -> VoiceCommandLatencySession {
        let session = VoiceCommandLatencySession()
        active = session
        session.markVoiceCommandStarted(startReason: "typedSubmit")
        return session
    }

    static func attach(_ session: VoiceCommandLatencySession?) {
        active = session
    }

    static func clear() {
        active = nil
    }

    static func recordTranscribeBackendCall() async {
        await MainActor.run { active?.recordTranscribeBackendCall() }
    }

    static func recordInterpretBackendCall() async {
        await MainActor.run { active?.recordInterpretBackendCall() }
    }

    static func recordParseBackendCall() async {
        await MainActor.run { active?.recordParseBackendCall() }
    }

    static func recordResolveBackendCall() async {
        await MainActor.run { active?.recordResolveBackendCall() }
    }

    static func markInterpretRequestStart() async {
        await MainActor.run { active?.markInterpretRequestStart() }
    }

    static func markInterpretSucceeded() async {
        await MainActor.run { active?.markInterpretSucceeded() }
    }

    static func markInterpretRequestComplete(responseBytes: Int, actionsCount: Int, durationMs: Int) async {
        await MainActor.run {
            active?.markInterpretRequestComplete(responseBytes: responseBytes, actionsCount: actionsCount, durationMs: durationMs)
        }
    }
}
