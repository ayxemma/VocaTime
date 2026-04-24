import Foundation
import os.log
import SwiftData
import SwiftUI

private func latencyMs(since start: CFAbsoluteTime) -> Int {
    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
}

// MARK: - Chat types (unchanged)

enum ChatMessageRole: String, Equatable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatMessageRole
    var text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: ChatMessageRole, text: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

enum VoiceFlowState: Equatable {
    case idle
    case listening
    case processing
    case conflictPending
    case deletePending
    case disambiguating
    case success
    case error
}

// MARK: - Transcript source (for logging and parse-strategy selection)

private enum TranscriptSource {
    case local
    case cloud
}

// MARK: - ViewModel

@MainActor
@Observable
final class VoiceCommandViewModel {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "VoiceChat")

    // MARK: - Public state (unchanged from previous version)

    var chatMessages: [ChatMessage] = []
    var chatFlowState: VoiceFlowState = .idle {
        didSet {
            if oldValue == .processing, chatFlowState != .processing {
                cancelAllProcessingStatusHints()
                cancelStreamReveal()
            }
            if chatFlowState == .processing, oldValue != .processing {
                scheduleProcessingStatusSequence()
            }
        }
    }
    var chatDraftText: String = ""
    /// Set after voice capture completes. The view observes this and moves it into the text
    /// field so the user can review and edit before sending. Cleared by the view after pickup.
    var pendingVoiceTranscript: String = ""
    var parsedCommand: ParsedCommand?
    var disambiguationCandidates: [TaskItem] = []
    /// Most recent task touched in this chat session; sent to backend parse for follow-ups. Cleared on sheet dismiss.
    var lastActiveChatTaskContext: ChatActiveTaskContext?

    private var pendingConflictCommand: ParsedCommand?
    private var pendingDeleteTask: TaskItem?
    private var pendingEditAction: PendingEditAction?

    // MARK: - Pending edit model (unchanged)

    private enum PendingEditType {
        case delete
        case reschedule(newDate: Date)
        case appendNote(text: String)
        case rename(to: String)
    }

    private struct PendingEditAction {
        let type: PendingEditType
    }

    var uiLanguage: AppUILanguage = .defaultForDevice()

    // MARK: - Services (injectable for testing)

    private let speechService: any SpeechManaging
    private let transcriptionService: any FallbackTranscribing
    private let transcriptionRouter: any TranscriptionRouting
    private let localEvaluator: LocalTranscriptEvaluator

    /// Main parsing coordinator. Strategy is set per-call depending on whether the transcript
    /// came from local recognition (`.localFirst`) or cloud transcription (`.llmFirst`).
    private var parsingCoordinator: TaskParsingCoordinator

    private var persistenceContext: ModelContext?
    private var silenceTimerTask: Task<Void, Never>?
    /// Single delayed "slow server" UI hint; cancelled on any processing exit or rescheduling.
    private var wakeUpHintTask: Task<Void, Never>?
    private var showSlowBackendHint = false
    private var thinkingStatusTask: Task<Void, Never>?
    private var showExtendedThinkingStatus = false
    /// Bumps when the hint is invalidated so a delayed task cannot flip UI after state changes.
    private var processingSlowHintEpoch: UInt = 0
    /// Invalidates the 800ms “Thinking…” timer when processing ends or is rescheduled.
    private var thinkingStatusEpoch: UInt = 0
    /// Bumps when a stream is superseded/cancelled so only the latest stream may mutate bubbles.
    private var streamEpoch: UInt = 0
    private var streamRevealTask: Task<Void, Never>?
    /// When set, the next assistant reply should fill this bubble (or append if not found).
    /// Used only for typed send / parse flow — not for cloud STT (draft stays in the composer).
    private var pendingAssistantSlotId: UUID?
    /// Voice draft / cloud transcription error shown in the status line; never adds a chat bubble.
    private var voiceDraftErrorMessage: String?

    // MARK: - Init

    init(
        speechService: (any SpeechManaging)? = nil,
        transcriptionService: (any FallbackTranscribing)? = nil,
        transcriptionRouter: (any TranscriptionRouting)? = nil,
        localEvaluator: LocalTranscriptEvaluator? = nil,
        parsingCoordinator: TaskParsingCoordinator? = nil
    ) {
        self.speechService = speechService ?? SpeechRecognizerService()
        self.transcriptionService = transcriptionService ?? MultilingualTranscriptionService()
        self.transcriptionRouter = transcriptionRouter ?? TranscriptionRouter()
        self.localEvaluator = localEvaluator ?? LocalTranscriptEvaluator()
        self.parsingCoordinator = parsingCoordinator ?? TaskParsingCoordinator(
            localParser: LocalTaskParser(),
            llmParser: LLMTaskParserService(),
            strategy: .localFirst
        )
    }

    func attachPersistence(_ context: ModelContext) {
        persistenceContext = context
    }

    // MARK: - Status text

    var chatStatusDescription: String {
        let s = uiLanguage.strings
        switch chatFlowState {
        case .idle:       return s.voiceTapToSpeak
        case .listening:  return s.voiceListening
        case .processing:
            if showSlowBackendHint { return s.voiceWakingUpServer }
            if showExtendedThinkingStatus { return s.chatAssistantThinking }
            return s.voiceProcessing
        case .conflictPending, .deletePending, .disambiguating: return ""
        case .success:    return s.voiceReady
        case .error:      return voiceDraftErrorMessage ?? s.voiceError
        }
    }

    func handleUILanguageChanged() async {
        await speechService.cancelForReset()
        cancelMaxRecordingTimer()
        if chatFlowState == .listening {
            chatFlowState = .idle
            chatDraftText = ""
        }
    }

    // MARK: - Typed text entry point

    /// Submits a typed string directly into the parse → save flow, bypassing transcription.
    /// Safe to call from any ready state (idle, success, error). No-op while processing.
    func chatSubmitTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard chatFlowState == .idle || chatFlowState == .success || chatFlowState == .error else { return }

        Self.log.info("[VoiceChat] typedTextSubmit text=\(trimmed, privacy: .public)")
        voiceDraftErrorMessage = nil
        // Perception: user bubble + empty assistant row immediately, then non-blocking warm-up, then work.
        chatMessages.append(ChatMessage(role: .user, text: trimmed))
        let slotId = UUID()
        chatMessages.append(ChatMessage(id: slotId, role: .assistant, text: ""))
        pendingAssistantSlotId = slotId
        chatFlowState = .processing
        parsingCoordinator.strategy = .localFirst
        BackendWarmup.scheduleSessionWarmup()
        await applyChatParse(transcript: trimmed)
    }

    /// Cancels the current recording session without processing any audio.
    /// Used when the user taps the text field while listening, signalling they prefer to type.
    func chatCancelListening() async {
        guard chatFlowState == .listening else { return }
        cancelMaxRecordingTimer()
        speechService.onPartialTranscript = nil
        await speechService.cancelForReset()
        chatFlowState = .idle
        chatDraftText = ""
        Self.log.info("[VoiceChat] listeningCancelled — user switched to text input")
    }

    // MARK: - Mic tap entry point (unchanged)

    func chatMicrophoneTapped() {
        switch chatFlowState {
        case .idle, .success, .error:
            Task { await chatBeginListening() }
        case .listening:
            Self.log.info("[VoiceChat] userTappedStop stopReason=manual")
            Task { await chatFinalizeListening() }
        case .processing, .conflictPending, .deletePending, .disambiguating:
            break
        }
    }

    // MARK: - Max-duration safety net (unchanged)

    private static let maxRecordingNanoseconds: UInt64 = 30_000_000_000

    private func startMaxRecordingTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxRecordingNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.chatFlowState == .listening else { return }
            Self.log.info("[VoiceChat] stopReason=maxTimeout — safety net fired after 30 s")
            await self.chatFinalizeListening()
        }
    }

    private func cancelMaxRecordingTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
    }

    private func scheduleProcessingStatusSequence() {
        scheduleExtendedThinkingStatus()
        scheduleSlowBackendHint()
    }

    private func scheduleExtendedThinkingStatus() {
        thinkingStatusTask?.cancel()
        showExtendedThinkingStatus = false
        thinkingStatusEpoch &+= 1
        let epoch = thinkingStatusEpoch
        thinkingStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.thinkingStatusEpoch == epoch else { return }
            guard self.chatFlowState == .processing else { return }
            self.showExtendedThinkingStatus = true
        }
    }

    private func scheduleSlowBackendHint() {
        wakeUpHintTask?.cancel()
        wakeUpHintTask = nil
        showSlowBackendHint = false
        processingSlowHintEpoch &+= 1
        let epoch = processingSlowHintEpoch
        wakeUpHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.processingSlowHintEpoch == epoch else { return }
            guard self.chatFlowState == .processing else { return }
            self.showSlowBackendHint = true
        }
    }

    private func cancelAllProcessingStatusHints() {
        thinkingStatusEpoch &+= 1
        thinkingStatusTask?.cancel()
        thinkingStatusTask = nil
        showExtendedThinkingStatus = false
        wakeUpHintTask?.cancel()
        wakeUpHintTask = nil
        showSlowBackendHint = false
        processingSlowHintEpoch &+= 1
    }

    private func cancelStreamReveal() {
        streamRevealTask?.cancel()
        streamRevealTask = nil
        // Bump so in-flight stream loops see streamEpoch != myToken and stop without calling onComplete.
        streamEpoch &+= 1
    }

    /// Cancels delayed caption timers while inactive; restarts them when returning to `active` during an in-flight request.
    func handleAppScenePhaseChange(_ phase: ScenePhase) {
        if phase == .background || phase == .inactive {
            cancelAllProcessingStatusHints()
        } else if phase == .active, chatFlowState == .processing {
            scheduleProcessingStatusSequence()
        }
    }

    // MARK: - Assistant text reveal (perception; does not change backend)

    private func startStreamingText(into id: UUID, fullText: String, onComplete: @escaping () -> Void) {
        cancelStreamReveal()
        // Token captured after cancel: superseded streams retain an older token and must not update UI.
        let myToken = streamEpoch
        if fullText.isEmpty {
            if let idx = chatMessages.firstIndex(where: { $0.id == id && $0.role == .assistant }) {
                chatMessages[idx].text = ""
            }
            onComplete()
            return
        }
        let charCount = fullText.count
        let instantReveal = charCount <= 8
        let chunkSize = instantReveal ? charCount : min(4, charCount)
        let delayNs: UInt64 = instantReveal ? 0 : 32_000_000
        streamRevealTask = Task { @MainActor [weak self] in
            let chars = Array(fullText)
            var offset = 0
            while offset < chars.count {
                if Task.isCancelled { return }
                guard let s = self else { return }
                guard s.streamEpoch == myToken else { return }
                let end = min(offset + chunkSize, chars.count)
                offset = end
                if let idx = s.chatMessages.firstIndex(where: { $0.id == id && $0.role == .assistant }) {
                    s.chatMessages[idx].text = String(chars[0..<offset])
                }
                if offset >= chars.count { break }
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
            }
            guard let s = self, !Task.isCancelled, s.streamEpoch == myToken else { return }
            onComplete()
        }
    }

    /// Inserts or replaces the pending assistant slot, optionally with a streaming “typing” reveal.
    private func emitAssistantResponse(_ text: String, nextState: VoiceFlowState, stream: Bool) {
        if stream, !text.isEmpty {
            if let slot = pendingAssistantSlotId, chatMessages.contains(where: { $0.id == slot && $0.role == .assistant }) {
                pendingAssistantSlotId = nil
                startStreamingText(into: slot, fullText: text) { [weak self] in
                    self?.chatFlowState = nextState
                }
            } else {
                let slot = UUID()
                chatMessages.append(ChatMessage(id: slot, role: .assistant, text: ""))
                startStreamingText(into: slot, fullText: text) { [weak self] in
                    self?.chatFlowState = nextState
                }
            }
        } else {
            // Non-stream path replaces the bubble in one step; must invalidate any in-progress stream first.
            cancelStreamReveal()
            if let slot = pendingAssistantSlotId, let idx = chatMessages.firstIndex(where: { $0.id == slot && $0.role == .assistant }) {
                pendingAssistantSlotId = nil
                chatMessages[idx].text = text
            } else {
                chatMessages.append(ChatMessage(role: .assistant, text: text))
            }
            chatFlowState = nextState
        }
    }

    // MARK: - Begin listening

    func chatBeginListening() async {
        voiceDraftErrorMessage = nil
        cancelMaxRecordingTimer()

        let msgs = uiLanguage.speechMessages
        Self.log.info("[VoiceChat] recordingStarted appUILanguage=\(self.uiLanguage.rawValue, privacy: .public)")

        // Keep Apple partials internal only; multilingual chat displays the backend transcript after stop.
        speechService.onPartialTranscript = { [weak self] text in
            guard let self, self.chatFlowState == .listening else { return }
            Self.log.info("[VoiceChat] localPartialReceived chars=\(text.count, privacy: .public) hiddenFromUI=true")
        }

        // Request both microphone + speech recognition permissions.
        // Speech recognition denial degrades to audio-only — not a fatal error.
        if let err = await speechService.requestAuthorizationIfNeeded(messages: msgs) {
            emitAssistantResponse(err, nextState: .error, stream: false)
            return
        }

        chatDraftText = ""

        let startError = await speechService.startListening(
            locale: uiLanguage.locale,
            messages: msgs,
            autoStopBehavior: .disabled,
            onAutoStop: nil
        )

        if let startError {
            emitAssistantResponse(startError, nextState: .error, stream: false)
            return
        }

        chatFlowState = .listening
        startMaxRecordingTimer()
        Self.log.info("[VoiceChat] listening active — tap-to-stop; auto silence disabled; max timeout=30s")
    }

    // MARK: - Finalize listening (orchestrator)

    func chatFinalizeListening() async {
        guard chatFlowState == .listening else { return }
        cancelMaxRecordingTimer()
        chatFlowState = .processing
        chatDraftText = ""

        let pipelineT0 = CFAbsoluteTimeGetCurrent()
        Self.log.info("[VoiceChat] stoppingListening")
        let stopT0 = CFAbsoluteTimeGetCurrent()
        let captureOutcome = await speechService.stopListening(waitForLocalFinal: false)
        Self.log.info("[VoiceChat] latency stopListening ms=\(latencyMs(since: stopT0), privacy: .public)")
        let strings = uiLanguage.strings
        let speechMsgs = uiLanguage.speechMessages

        switch captureOutcome {
        case .failure(let error):
            handleCaptureFailure(error, strings: strings, speechMsgs: speechMsgs)
            Self.log.info("[VoiceChat] latency chatFinalizeListening totalMs=\(latencyMs(since: pipelineT0), privacy: .public) outcome=failure")

        case .success(let captureResult):
            Self.log.info("[VoiceChat] captureSuccess localTranscript=\(captureResult.transcript, privacy: .public) confidence=\(String(describing: captureResult.confidence), privacy: .public) duration=\(captureResult.duration, privacy: .public)s audioURL=\(captureResult.audioURL?.path ?? "nil", privacy: .public)")
            await handleCloudAuthoritativeSpeechResult(captureResult, strings: strings)
            Self.log.info("[VoiceChat] latency chatFinalizeListening totalMs=\(latencyMs(since: pipelineT0), privacy: .public) outcome=success")
        }
    }

    // MARK: - Capture failure handler

    private func handleCaptureFailure(_ error: Error, strings: AppStrings, speechMsgs: SpeechServiceMessages) {
        let ns = error as NSError
        let userMsg: String
        if ns.domain == VocaTimeSpeechDomain.name,
           ns.code == VocaTimeSpeechErrorCode.recordingFailed.rawValue,
           ns.localizedDescription.contains("too small") {
            userMsg = strings.chatEmptyTranscript
        } else {
            userMsg = localizedStopFailure(error, speechMsgs: speechMsgs)
        }
        emitAssistantResponse(userMsg, nextState: .error, stream: false)
        parsedCommand = nil
    }

    // MARK: - Local speech result handler

    private func handleLocalSpeechResult(
        _ captureResult: LocalSpeechCaptureResult,
        strings: AppStrings
    ) async {
        // Quick local eval to inform the routing decision (no network).
        let evalT0 = CFAbsoluteTimeGetCurrent()
        let localParsed = await localEvaluator.evaluate(
            transcript: captureResult.transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        Self.log.info("[VoiceChat] latency localEvaluator.evaluate ms=\(latencyMs(since: evalT0), privacy: .public)")

        let routerT0 = CFAbsoluteTimeGetCurrent()
        let routingDecision = transcriptionRouter.evaluate(
            transcript: captureResult.transcript,
            confidence: captureResult.confidence,
            duration: captureResult.duration,
            parsedCommand: localParsed
        )
        Self.log.info("[VoiceChat] latency transcriptionRouter.evaluate ms=\(latencyMs(since: routerT0), privacy: .public)")

        switch routingDecision {
        case .acceptLocalTranscript(let trimmed):
            Self.log.info("[VoiceChat] routingDecision=acceptLocal transcript=\(trimmed, privacy: .public)")
            defer { deleteAudioFile(captureResult.audioURL) }
            deliverTranscriptToInputField(trimmed)

        case .fallbackToCloud:
            guard let audioURL = captureResult.audioURL else {
                // Same draft-only UX as other cloud / voice-input failures: status line, not chat bubble.
                voiceDraftErrorMessage = strings.chatErrorNothingRecorded
                chatFlowState = .error
                return
            }
            Self.log.info("[VoiceChat] routingDecision=fallbackToCloud — uploading audio")
            await handleCloudFallback(audioURL: audioURL, strings: strings)
        }
    }

    private func handleCloudAuthoritativeSpeechResult(
        _ captureResult: LocalSpeechCaptureResult,
        strings: AppStrings
    ) async {
        guard let audioURL = captureResult.audioURL else {
            voiceDraftErrorMessage = strings.chatErrorNothingRecorded
            chatFlowState = .error
            return
        }
        Self.log.info("[VoiceChat] routingDecision=cloudAuthoritative localTranscriptChars=\(captureResult.transcript.count, privacy: .public) confidence=\(String(describing: captureResult.confidence), privacy: .public)")
        await handleCloudFallback(audioURL: audioURL, strings: strings)
    }

    // MARK: - Cloud fallback handler

    private func handleCloudFallback(audioURL: URL, strings: AppStrings) async {
        defer { deleteAudioFile(audioURL) }
        // Cloud STT is user-typed draft data only: no assistant row, no streaming, no emitAssistantResponse.
        let cloudT0 = CFAbsoluteTimeGetCurrent()

        let transcript: String
        do {
            Self.log.info("[VoiceChat] cloudTranscriptionStart audioURL=\(audioURL.path, privacy: .public)")
            let transcribeT0 = CFAbsoluteTimeGetCurrent()
            transcript = try await transcriptionService.transcribe(audioFileURL: audioURL)
            Self.log.info("[VoiceChat] latency transcriptionService.transcribe ms=\(latencyMs(since: transcribeT0), privacy: .public)")
            Self.log.info("[VoiceChat] cloudTranscriptionSuccess transcript=\(transcript, privacy: .public)")
        } catch {
            // Map each error category to a precise log string (for debugging)
            // and a clean user-facing message (no API / HTTP / internal terms).
            let rootCause: String
            let userMessage: String
            let requestIdForLog: String
            switch error {
            case MultilingualTranscriptionError.fileReadFailed(let u, let rid):
                requestIdForLog = rid.uuidString
                rootCause = "fileReadFailed — \(u.localizedDescription)"
                userMessage = strings.chatErrorSomethingWentWrong
            case MultilingualTranscriptionError.fileEmpty(let rid):
                requestIdForLog = rid.uuidString
                rootCause = "fileEmpty — audio file was empty or contained no speech frames"
                userMessage = strings.chatErrorNothingRecorded
            case MultilingualTranscriptionError.networkError(let u, let rid):
                requestIdForLog = rid.uuidString
                rootCause = "networkError — \(u.localizedDescription)"
                userMessage = BackendUserFacingErrorMessages.transcriptionNetwork(strings: strings, underlying: u)
            case MultilingualTranscriptionError.httpError(let code, let body, let rid):
                requestIdForLog = rid.uuidString
                rootCause = "httpError — status=\(code) body=\(body.prefix(200))"
                userMessage = strings.chatErrorServiceUnavailable
            case MultilingualTranscriptionError.decodingFailed(let u, let raw, let rid):
                requestIdForLog = rid.uuidString
                rootCause = "decodingFailed — \(u.localizedDescription) rawBody=\(raw.prefix(200))"
                userMessage = strings.chatErrorSomethingWentWrong
            default:
                requestIdForLog = "—"
                rootCause = "unknown — \(String(describing: error))"
                userMessage = strings.chatErrorSomethingWentWrong
            }
            Self.log.error("[VoiceChat] cloudTranscriptionFailure requestId=\(requestIdForLog, privacy: .public) rootCause=\(rootCause, privacy: .public)")
            Self.log.info("[VoiceChat] latency handleCloudFallback totalMs=\(latencyMs(since: cloudT0), privacy: .public) outcome=failure")
            voiceDraftErrorMessage = userMessage
            chatFlowState = .error
            parsedCommand = nil
            return
        }

        deliverTranscriptToInputField(transcript)
        Self.log.info("[VoiceChat] latency handleCloudFallback totalMs=\(latencyMs(since: cloudT0), privacy: .public) outcome=success")
    }

    // MARK: - Transcript → input field delivery

    /// Places the transcribed text into the input field for the user to review and send.
    /// This is the final step of the voice pipeline — the user then taps send (or return)
    /// which routes through `chatSubmitTypedText`, the same path as manual typed input.
    private func deliverTranscriptToInputField(_ rawTranscript: String) {
        let deliverT0 = CFAbsoluteTimeGetCurrent()
        defer {
            Self.log.info("[VoiceChat] latency deliverTranscriptToInputField ms=\(latencyMs(since: deliverT0), privacy: .public)")
        }
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Transcript is user draft input — surface empty result in status only, not as assistant chat.
            voiceDraftErrorMessage = uiLanguage.strings.chatEmptyTranscript
            chatFlowState = .error
            return
        }
        Self.log.info("[VoiceChat] transcriptDeliveredToInputField=\(trimmed, privacy: .public)")
        voiceDraftErrorMessage = nil
        pendingVoiceTranscript = trimmed
        chatFlowState = .idle
    }

    // MARK: - Parse + route to task actions (largely unchanged)

    func applyChatParse(transcript: String) async {
        Self.log.info("[VoiceChat] parse input appUILanguage=\(self.uiLanguage.rawValue, privacy: .public) transcript=\(transcript, privacy: .public)")
        let command = await parsingCoordinator.parse(
            text: transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            activeTaskContext: lastActiveChatTaskContext
        )
        Self.log.info("[VoiceChat] parse outcome actionType=\(String(describing: command.actionType), privacy: .public) parserSource=\(String(describing: command.parserSource), privacy: .public) title=\(command.title, privacy: .public)")
        parsedCommand = command

        // ── Route edit intents ────────────────────────────────────────────────
        switch command.actionType {
        case .deleteTask:
            handleDeleteIntent(command)
            return
        case .rescheduleTask:
            handleRescheduleIntent(command)
            return
        case .appendToTask:
            handleAppendIntent(command)
            return
        case .updateTaskTitle:
            handleUpdateTitleIntent(command)
            return
        default:
            break
        }

        // ── Create: conflict check then save ─────────────────────────────────
        let scheduledDate = command.reminderDate ?? command.startDate
        print("""
        [VoiceChat] conflictCheckInput
          newTitle='\(command.title)'
          reminderDate=\(String(describing: command.reminderDate))
          startDate=\(String(describing: command.startDate))
          resolvedScheduledDate=\(String(describing: scheduledDate))
          timeZone=\(TimeZone.current.identifier)
          hasWallClockTime=\(scheduledDate.map { TaskScheduleFormatting.hasWallClockTime($0) } ?? false)
        """)
        if let date = scheduledDate,
           TaskScheduleFormatting.hasWallClockTime(date),
           let conflicting = findConflictingTask(near: date) {
            // Use the EXISTING conflicting task's own scheduledDate for the time string
            // so the warning says "you already have X at <X's actual time>", not the
            // new task's proposed time.
            let conflictingDate = conflicting.scheduledDate ?? date
            let timeStr = shortTimeFormatter.string(from: conflictingDate)
            let warning = String(format: uiLanguage.strings.chatConflictWarning,
                                 conflicting.title, timeStr, command.title)
            Self.log.info("""
                [VoiceChat] conflictDetected \
                existingTitle=\(conflicting.title, privacy: .public) \
                existingScheduledDate=\(String(describing: conflicting.scheduledDate), privacy: .public) \
                newTitle=\(command.title, privacy: .public) \
                newScheduledDate=\(String(describing: date), privacy: .public) \
                warningTimeStr=\(timeStr, privacy: .public)
                """)
            print("""
            [VoiceChat] conflictDetected
              existing: '\(conflicting.title)' at \(String(describing: conflicting.scheduledDate))
              new:      '\(command.title)' proposed at \(date)
              warningTimeStr=\(timeStr)
              warning=\(warning)
            """)
            pendingConflictCommand = command
            emitAssistantResponse(warning, nextState: .conflictPending, stream: true)
            return
        }

        commitSave(command: command)
    }

    // MARK: - Edit intent handlers (unchanged)

    private func handleUpdateTitleIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        let newTitle = command.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newTitle.isEmpty else {
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        switch resolveTargetTask(near: command.targetDate, activeFallback: lastActiveChatTaskContext) {
        case .notFound:
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
        case .ambiguous(let matches):
            enterDisambiguation(matches: matches, editType: .rename(to: newTitle), strings: s)
        case .found(let task):
            applyRename(task: task, newTitle: newTitle, strings: s)
        }
    }

    private func handleDeleteIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        switch resolveTargetTask(near: command.targetDate, activeFallback: lastActiveChatTaskContext) {
        case .notFound:
            Self.log.info("[VoiceChat] deleteIntent — no task found near targetDate=\(String(describing: command.targetDate), privacy: .public)")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
        case .ambiguous(let matches):
            Self.log.info("[VoiceChat] deleteIntent — ambiguous matchCount=\(matches.count, privacy: .public)")
            enterDisambiguation(matches: matches, editType: .delete, strings: s)
        case .found(let task):
            Self.log.info("[VoiceChat] deleteIntent — found task title=\(task.title, privacy: .public)")
            enterDeleteConfirmation(for: task, strings: s)
        }
    }

    private func handleRescheduleIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        switch resolveTargetTask(near: command.targetDate, activeFallback: lastActiveChatTaskContext) {
        case .notFound:
            Self.log.info("[VoiceChat] rescheduleIntent — no task found")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
        case .ambiguous(let matches):
            Self.log.info("[VoiceChat] rescheduleIntent — ambiguous matchCount=\(matches.count, privacy: .public)")
            guard let newDate = command.newScheduledDate else {
                emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
                return
            }
            enterDisambiguation(matches: matches, editType: .reschedule(newDate: newDate), strings: s)
        case .found(let task):
            guard let newDate = command.newScheduledDate else {
                Self.log.warning("[VoiceChat] rescheduleIntent — newScheduledDate is nil")
                emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
                return
            }
            applyReschedule(task: task, newDate: newDate, strings: s)
        }
    }

    private func handleAppendIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        let text = command.appendText ?? command.title
        guard !text.isEmpty else {
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        switch resolveTargetTask(near: command.targetDate, activeFallback: lastActiveChatTaskContext) {
        case .notFound:
            Self.log.info("[VoiceChat] appendIntent — no task found")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
        case .ambiguous(let matches):
            Self.log.info("[VoiceChat] appendIntent — ambiguous matchCount=\(matches.count, privacy: .public)")
            enterDisambiguation(matches: matches, editType: .appendNote(text: text), strings: s)
        case .found(let task):
            applyAppend(task: task, text: text, strings: s)
        }
    }

    // MARK: - Disambiguation (unchanged)

    private static let disambiguationLimit = 5

    private func enterDisambiguation(matches: [TaskItem], editType: PendingEditType, strings s: AppStrings) {
        if matches.count > Self.disambiguationLimit {
            emitAssistantResponse(s.chatEditAmbiguousTask, nextState: .error, stream: false)
            return
        }
        Self.log.info("[VoiceChat] enterDisambiguation count=\(matches.count, privacy: .public)")
        disambiguationCandidates = matches
        pendingEditAction = PendingEditAction(type: editType)
        emitAssistantResponse(String(format: s.chatDisambiguateSelect, matches.count), nextState: .disambiguating, stream: true)
    }

    func chatSelectCandidate(_ task: TaskItem) {
        guard let action = pendingEditAction else { return }
        pendingEditAction = nil
        disambiguationCandidates = []
        let s = uiLanguage.strings
        Self.log.info("[VoiceChat] candidateSelected title=\(task.title, privacy: .public)")
        switch action.type {
        case .delete:
            enterDeleteConfirmation(for: task, strings: s)
        case .reschedule(let newDate):
            applyReschedule(task: task, newDate: newDate, strings: s)
        case .appendNote(let text):
            applyAppend(task: task, text: text, strings: s)
        case .rename(let newTitle):
            applyRename(task: task, newTitle: newTitle, strings: s)
        }
    }

    // MARK: - Shared edit operations (unchanged)

    private func enterDeleteConfirmation(for task: TaskItem, strings s: AppStrings) {
        pendingDeleteTask = task
        let prompt = String(format: s.chatDeletePrompt, task.title)
        emitAssistantResponse(prompt, nextState: .deletePending, stream: true)
    }

    private func applyReschedule(task: TaskItem, newDate: Date, strings s: AppStrings) {
        Self.log.info("[VoiceChat] rescheduleApplied title=\(task.title, privacy: .public) newDate=\(newDate, privacy: .public)")
        task.scheduledDate = newDate
        task.updatedAt = Date()
        try? persistenceContext?.save()
        TaskReminderService.shared.schedule(for: task)
        let timeStr = shortTimeFormatter.string(from: newDate)
        let msg = assistantSuccessMessage(base: String(format: s.chatRescheduleSuccess, task.title, timeStr))
        emitAssistantResponse(msg, nextState: .success, stream: true)
        refreshActiveContext(from: task)
    }

    private func applyAppend(task: TaskItem, text: String, strings s: AppStrings) {
        Self.log.info("[VoiceChat] appendApplied title=\(task.title, privacy: .public)")
        if let existing = task.notes, !existing.isEmpty {
            task.notes = existing + "\n" + text
        } else {
            task.notes = text
        }
        task.updatedAt = Date()
        try? persistenceContext?.save()
        emitAssistantResponse(assistantSuccessMessage(base: String(format: s.chatAppendSuccess, task.title)), nextState: .success, stream: true)
        refreshActiveContext(from: task)
    }

    private func applyRename(task: TaskItem, newTitle: String, strings s: AppStrings) {
        Self.log.info("[VoiceChat] renameApplied newTitle=\(newTitle, privacy: .public)")
        task.title = newTitle
        task.updatedAt = Date()
        try? persistenceContext?.save()
        emitAssistantResponse(assistantSuccessMessage(base: String(format: s.chatRenameSuccess, newTitle)), nextState: .success, stream: true)
        refreshActiveContext(from: task)
    }

    // MARK: - Delete confirmation (unchanged)

    func chatConfirmDelete() {
        guard let task = pendingDeleteTask else { return }
        let title = task.title
        let deletedId = task.id
        pendingDeleteTask = nil
        Self.log.info("[VoiceChat] deleteConfirmed title=\(title, privacy: .public)")
        if let ctx = persistenceContext {
            TaskReminderService.shared.cancel(taskID: task.id)
            ctx.delete(task)
            try? ctx.save()
        }
        if lastActiveChatTaskContext?.taskID == deletedId {
            lastActiveChatTaskContext = nil
        }
        emitAssistantResponse(String(format: uiLanguage.strings.chatDeleteSuccess, title), nextState: .success, stream: true)
    }

    func chatCancelDelete() {
        pendingDeleteTask = nil
        emitAssistantResponse(uiLanguage.strings.chatDeleteCanceled, nextState: .error, stream: false)
    }

    // MARK: - Conflict confirmation (unchanged)

    func chatConfirmConflict() {
        guard let command = pendingConflictCommand else { return }
        pendingConflictCommand = nil
        commitSave(command: command)
    }

    func chatCancelConflict() {
        pendingConflictCommand = nil
        emitAssistantResponse(uiLanguage.strings.chatConflictCanceled, nextState: .error, stream: false)
    }

    // MARK: - Task resolution (unchanged)

    private enum TaskResolution {
        case found(TaskItem)
        case ambiguous([TaskItem])
        case notFound
    }

    private func resolveTargetTask(near targetDate: Date?, activeFallback: ChatActiveTaskContext?) -> TaskResolution {
        if let targetDate, let ctx = persistenceContext {
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { !$0.isCompleted }
            )
            let candidates = (try? ctx.fetch(descriptor)) ?? []
            let window: TimeInterval = 15 * 60
            let matches = candidates.filter { item in
                guard let d = item.scheduledDate,
                      TaskScheduleFormatting.hasWallClockTime(d) else { return false }
                return abs(d.timeIntervalSince(targetDate)) <= window
            }
            switch matches.count {
            case 1: return .found(matches[0])
            case 0: break
            default: return .ambiguous(matches)
            }
        }
        if let fb = activeFallback, let task = fetchIncompleteTask(id: fb.taskID) {
            return .found(task)
        }
        return .notFound
    }

    private func fetchIncompleteTask(id: UUID) -> TaskItem? {
        guard let ctx = persistenceContext else { return nil }
        let tid = id
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { $0.id == tid })
        descriptor.fetchLimit = 1
        guard let task = try? ctx.fetch(descriptor).first, !task.isCompleted else { return nil }
        return task
    }

    // MARK: - Helpers (unchanged)

    private func commitSave(command: ParsedCommand) {
        let reply = assistantSuccessMessage(base: confirmationMessage(for: command, userTranscript: command.originalText))
        if let ctx = persistenceContext {
            let resolvedDate = command.reminderDate ?? command.startDate
            print("""
            [VoiceChat] commitSave
              title='\(command.title)'
              scheduledDate=\(String(describing: resolvedDate))
              reminderOffsetMinutes=\(ReminderOffset.globalDefault.rawValue) (globalDefault)
            """)
            let item = TaskItem.insertFromParsedCommand(command, context: ctx)
            refreshActiveContext(from: item)
            Self.log.info("""
                [VoiceChat] taskSaveSuccess \
                title=\(command.title, privacy: .public) \
                scheduledDate=\(String(describing: resolvedDate), privacy: .public) \
                actionType=\(String(describing: command.actionType), privacy: .public)
                """)
        }
        emitAssistantResponse(reply, nextState: .success, stream: true)
    }

    private func assistantSuccessMessage(base: String) -> String {
        let hint = uiLanguage.strings.chatFollowUpHint
        if hint.isEmpty { return base }
        return base + "\n\n" + hint
    }

    private func refreshActiveContext(from task: TaskItem) {
        lastActiveChatTaskContext = ChatActiveTaskContext(
            taskID: task.id,
            title: task.title,
            scheduledDate: task.scheduledDate,
            notes: task.notes
        )
    }

    /// Returns the first incomplete task whose scheduled time falls on the same
    /// calendar day **and** the same exact hour+minute as `date`.
    ///
    /// The previous ±15-minute window was too broad: tasks 5 or 10 minutes apart
    /// were incorrectly treated as conflicting, making every closely-timed task
    /// appear to clash with the previous one.  Exact clock-time matching is the
    /// correct MVP rule for this app.
    private func findConflictingTask(near date: Date) -> TaskItem? {
        guard let ctx = persistenceContext else { return nil }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isCompleted }
        )
        let candidates = (try? ctx.fetch(descriptor)) ?? []
        let cal = Calendar.current
        let newHour   = cal.component(.hour,   from: date)
        let newMinute = cal.component(.minute, from: date)

        print("[ConflictCheck] scanning \(candidates.count) incomplete task(s) for exact-time match with \(date)")

        return candidates.first { item in
            guard let d = item.scheduledDate,
                  TaskScheduleFormatting.hasWallClockTime(d) else { return false }

            let sameDay    = cal.isDate(d, inSameDayAs: date)
            let sameHour   = cal.component(.hour,   from: d) == newHour
            let sameMinute = cal.component(.minute, from: d) == newMinute
            let isMatch    = sameDay && sameHour && sameMinute
            let diffMin    = abs(d.timeIntervalSince(date)) / 60

            print("""
            [ConflictCheck] candidate='\(item.title)' \
            existingDate=\(d) \
            diffMin=\(String(format: "%.1f", diffMin)) \
            sameDay=\(sameDay) sameHour=\(sameHour) sameMinute=\(sameMinute) \
            → match=\(isMatch)
            """)

            return isMatch
        }
    }

    private func deleteAudioFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        Self.log.info("[VoiceChat] audioFileDeleted path=\(url.path, privacy: .public)")
    }

    func prepareForNewSession() async {
        speechService.onPartialTranscript = nil
        await speechService.cancelForReset()
        cancelMaxRecordingTimer()
        cancelAllProcessingStatusHints()
        cancelStreamReveal()
        pendingAssistantSlotId = nil
        voiceDraftErrorMessage = nil
        showExtendedThinkingStatus = false
        chatFlowState = .idle
        chatDraftText = ""
        pendingVoiceTranscript = ""
        chatMessages = []
        parsedCommand = nil
        pendingConflictCommand = nil
        pendingDeleteTask = nil
        pendingEditAction = nil
        disambiguationCandidates = []
        lastActiveChatTaskContext = nil
        Self.log.info("[VoiceChat] chatDismissReset completed — state ready for new session")
    }

    private func localizedStopFailure(_ error: Error, speechMsgs: SpeechServiceMessages) -> String {
        let ns = error as NSError
        Self.log.error("[VoiceChat] captureFailure domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public)")
        if ns.domain == VocaTimeSpeechDomain.name, let code = VocaTimeSpeechErrorCode(rawValue: ns.code) {
            switch code {
            case .nothingToStop:   return speechMsgs.nothingToStop
            case .interrupted:     return speechMsgs.interrupted
            case .recordingFailed: return speechMsgs.recognitionStopped
            case .generic:         return speechMsgs.recognitionStopped
            }
        }
        // Unknown domain / code — log full detail, show generic message to user.
        return speechMsgs.recognitionStopped
    }

    private var shortTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = uiLanguage.locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }

    private func confirmationMessage(for command: ParsedCommand, userTranscript: String) -> String {
        let s = uiLanguage.strings
        if command.actionType == .unknown {
            let name = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if name.isEmpty {
                label = s.chatYourTask
            } else if uiLanguage == .en {
                label = "\u{201C}\(name)\u{201D}"
            } else {
                label = "\u{300C}\(name)\u{300D}"
            }
            return String(format: s.chatUnknownSchedule, label)
        }

        let low = userTranscript.lowercased()
        if command.actionType == .reminder {
            if let n = extractLeadingMinutes(from: low) {
                let base = n == 1
                    ? String(format: s.chatReminderMinutes, n, command.title)
                    : String(format: s.chatReminderMinutesPlural, n, command.title)
                return appendAlsoNotedIfNeeded(base, notes: command.notes)
            }
            if let n = extractLeadingHours(from: low) {
                let base = n == 1
                    ? String(format: s.chatReminderHours, n, command.title)
                    : String(format: s.chatReminderHoursPlural, n, command.title)
                return appendAlsoNotedIfNeeded(base, notes: command.notes)
            }
            if let when = command.reminderDate {
                let t = replyDateFormatter.string(from: when)
                let base = String(format: s.chatReminderAt, t, command.title)
                return appendAlsoNotedIfNeeded(base, notes: command.notes)
            }
            let base = String(format: s.chatReminderAbout, command.title)
            return appendAlsoNotedIfNeeded(base, notes: command.notes)
        }
        if command.actionType == .calendarEvent {
            if let when = command.startDate {
                let t = replyDateFormatter.string(from: when)
                let base = String(format: s.chatEventAt, command.title, t)
                return appendAlsoNotedIfNeeded(base, notes: command.notes)
            }
            let base = String(format: s.chatEventCalendar, command.title)
            return appendAlsoNotedIfNeeded(base, notes: command.notes)
        }
        return s.chatTryRemind
    }

    /// Appends a second sentence when `notes` is non-empty; does not repeat the title.
    private func appendAlsoNotedIfNeeded(_ base: String, notes: String?) -> String {
        let s = uiLanguage.strings
        guard let snippet = truncatedNotesForConfirmation(notes) else { return base }
        return base + " " + String(format: s.chatAlsoNoted, snippet)
    }

    /// Truncates long notes; trims trailing sentence punctuation to avoid awkward doubling before `chatAlsoNoted`.
    private func truncatedNotesForConfirmation(_ notes: String?, maxLen: Int = 120) -> String? {
        guard var n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        while let last = n.last, ".。!！?？".contains(last) {
            n.removeLast()
        }
        guard !n.isEmpty else { return nil }
        guard n.count > maxLen else { return n }
        let end = n.index(n.startIndex, offsetBy: maxLen)
        var s = String(n[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, ".。!！?？".contains(last) { s.removeLast() }
        return s + "…"
    }

    private var replyDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = uiLanguage.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private func extractLeadingMinutes(from low: String) -> Int? {
        matchNumber(prefixPattern: #"in\s+(\d+)\s+minutes?"#, in: low)
    }

    private func extractLeadingHours(from low: String) -> Int? {
        matchNumber(prefixPattern: #"in\s+(\d+)\s+hours?"#, in: low)
    }

    private func matchNumber(prefixPattern: String, in low: String) -> Int? {
        let ns = low as NSString
        guard let regex = try? NSRegularExpression(pattern: "^\(prefixPattern)", options: .caseInsensitive),
              let m = regex.firstMatch(in: low, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: low),
              let n = Int(low[r]), n > 0
        else { return nil }
        return n
    }
}
