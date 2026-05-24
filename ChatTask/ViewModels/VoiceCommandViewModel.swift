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
    /// Shows the Important priority badge on assistant confirmations (e.g. alert style updates).
    var showsImportantPriorityBadge: Bool

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        text: String,
        timestamp: Date = .now,
        showsImportantPriorityBadge: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.showsImportantPriorityBadge = showsImportantPriorityBadge
    }
}

enum VoiceFlowState: Equatable {
    case idle
    case listening
    case processing
    case conflictPending
    case deletePending
    case editConfirmationPending
    case disambiguating
    case success
    case error
}

enum VoiceStopReason: String {
    case manual
    case autoSilence
    case maxTimeout
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
    var confirmationCandidate: TaskItem?
    /// Most recent task touched in this chat session; sent to backend parse for follow-ups. Cleared on sheet dismiss.
    var lastActiveChatTaskContext: ChatActiveTaskContext?

    /// Set from `ChatSheetView` so free-tier AI limits can be enforced before `POST /parse`.
    var subscriptionManager: SubscriptionManager?

    private var pendingConflictCommand: ParsedCommand?
    private var pendingDeleteTask: TaskItem?
    /// LLM command that led to the delete confirmation (for free-usage accounting).
    private var pendingDeleteUsageCommand: ParsedCommand?
    /// LLM command that led to disambiguation (for free-usage accounting after the user picks a task).
    private var pendingDisambiguationUsageCommand: ParsedCommand?
    /// LLM command that led to edit-target confirmation (for free-usage accounting after the user confirms).
    private var pendingConfirmationUsageCommand: ParsedCommand?
    private var pendingConfirmationPayload: PendingConfirmationPayload?
    private var pendingEditAction: PendingEditAction?

    // MARK: - Pending edit model (unchanged)

    private enum PendingEditType {
        case delete
        case reschedule(newDate: Date)
        case appendNote(text: String)
        case rename(to: String)
        case updateRecurrence(ParsedRecurrenceUpdate)
        case updateAlertStyle(ReminderAlertStyle)
    }

    private struct PendingEditAction {
        let type: PendingEditType
    }

    private enum PendingConfirmationPayload {
        case legacy(PendingEditType, ParsedCommand?)
        case interpreted(CommandInterpretResponse, transcript: String)
    }

    private struct InterpretedActionExecutionResult {
        let summary: String
    }

    private enum EditTargetConfidence: String {
        case high
        case medium
    }

    private enum TaskResolverConfig {
        static let highConfidence = 0.85
        static let candidateLimit = 20
        static let disambiguationLimit = 3
        static let nearbyTimeWindow: TimeInterval = 6 * 60 * 60
    }

    var uiLanguage: AppUILanguage = .defaultForDevice()

    // MARK: - Services (injectable for testing)

    private let speechService: any SpeechManaging
    private let transcriptionService: any FallbackTranscribing
    private let transcriptionRouter: any TranscriptionRouting
    private let localEvaluator: LocalTranscriptEvaluator
    private let taskTargetResolver: TaskTargetResolverService
    private let commandInterpreter: CommandInterpreterService

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
    private var autoRelistenTask: Task<Void, Never>?
    private var followUpNoSpeechTask: Task<Void, Never>?
    private var voiceDraftAwaitingSubmit = false
    private var currentSubmitCameFromVoiceDraft = false
    private var currentListeningIsAutoFollowUp = false
    private var voiceFollowUpAutoStartsRemaining = 0
    private var followUpSpeechDetected = false
    private var lastUnclearFeedbackAt: Date = .distantPast
    private var isChatSheetPresented = false
    private var isAppActive = true
    private var isTextEditing = false
    private var isStoppingListening = false
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
        parsingCoordinator: TaskParsingCoordinator? = nil,
        taskTargetResolver: TaskTargetResolverService = TaskTargetResolverService(),
        commandInterpreter: CommandInterpreterService = CommandInterpreterService()
    ) {
        self.speechService = speechService ?? SpeechRecognizerService()
        self.transcriptionService = transcriptionService ?? MultilingualTranscriptionService()
        self.transcriptionRouter = transcriptionRouter ?? TranscriptionRouter()
        self.localEvaluator = localEvaluator ?? LocalTranscriptEvaluator()
        self.taskTargetResolver = taskTargetResolver
        self.commandInterpreter = commandInterpreter
        self.parsingCoordinator = parsingCoordinator ?? TaskParsingCoordinator(
            localParser: LocalTaskParser(),
            llmParser: LLMTaskParserService(),
            strategy: .localFirst
        )
    }

    func attachPersistence(_ context: ModelContext) {
        persistenceContext = context
    }

    private var canUseAssistant: Bool {
        subscriptionManager?.canUseAssistant ?? true
    }

    private func showAssistantPaywall() {
        NotificationCenter.default.post(name: .chatTaskPresentPaywall, object: nil)
    }

    private func assistantAccessAllowed(logContext: String) -> Bool {
        let allowed = canUseAssistant
        Self.log.info("[PaywallGate] assistantAccessAllowed=\(allowed, privacy: .public) context=\(logContext, privacy: .public)")
        return allowed
    }

    private func handleAssistantAccessBlocked(context: String) async {
        Self.log.info("[PaywallGate] assistantAccessBlocked context=\(context, privacy: .public)")
        cancelAutoRelisten(reason: "paywallLocked")
        cancelMaxRecordingTimer()
        _ = cancelFollowUpNoSpeechTimer(reason: "paywallLocked")
        speechService.onPartialTranscript = nil
        speechService.onSpeechDetected = nil
        if chatFlowState == .listening {
            await speechService.cancelForReset()
            Self.log.info("[VoiceChat] voiceStartBlockedByPaywall")
        }
        isStoppingListening = false
        voiceFollowUpAutoStartsRemaining = 0
        currentListeningIsAutoFollowUp = false
        currentSubmitCameFromVoiceDraft = false
        removePendingAssistantSlotIfEmpty()
        pendingAssistantSlotId = nil
        chatFlowState = .idle
        showAssistantPaywall()
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
        case .conflictPending, .deletePending, .editConfirmationPending, .disambiguating: return ""
        case .success:    return s.voiceReady
        case .error:      return voiceDraftErrorMessage ?? s.voiceError
        }
    }

    func handleUILanguageChanged() async {
        cancelAutoRelisten(reason: "languageChanged")
        await speechService.cancelForReset()
        isStoppingListening = false
        cancelMaxRecordingTimer()
        if chatFlowState == .listening {
            chatFlowState = .idle
            chatDraftText = ""
        }
    }

    func chatSheetDidAppear() {
        isChatSheetPresented = true
        cancelAutoRelisten(reason: "sheetAppeared")
        guard assistantAccessAllowed(logContext: "chatSheetDidAppear") else {
            Self.log.info("[VoiceChat] voiceStartBlockedByPaywall")
            Task { await handleAssistantAccessBlocked(context: "chatSheetDidAppear") }
            return
        }
        Self.log.info("[VoiceChat] chatSheetPresented=true — starting initial listening")
        Task { await chatBeginListening(startReason: "sheetOpen") }
    }

    // MARK: - Typed text entry point

    /// Submits a typed string directly into the parse → save flow, bypassing transcription.
    /// Safe to call from any ready state (idle, success, error). No-op while processing.
    func chatSubmitTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard chatFlowState == .idle || chatFlowState == .success || chatFlowState == .error else { return }
        guard assistantAccessAllowed(logContext: "typedSubmit") else {
            await handleAssistantAccessBlocked(context: "typedSubmit")
            return
        }

        isTextEditing = false
        currentSubmitCameFromVoiceDraft = voiceDraftAwaitingSubmit
        voiceDraftAwaitingSubmit = false
        cancelAutoRelisten(reason: "typedSubmit")
        Self.log.info("[VoiceChat] typedTextSubmit text=\(trimmed, privacy: .public)")
        voiceDraftErrorMessage = nil
        // Perception: user bubble + empty assistant row immediately, then non-blocking warm-up, then work.
        chatMessages.append(ChatMessage(role: .user, text: trimmed))
        let slotId = UUID()
        chatMessages.append(ChatMessage(id: slotId, role: .assistant, text: ""))
        pendingAssistantSlotId = slotId
        chatFlowState = .processing
        parsingCoordinator.strategy = currentSubmitCameFromVoiceDraft ? .llmFirst : .localFirst
        BackendWarmup.scheduleSessionWarmup()
        await applyChatParse(transcript: trimmed)
    }

    /// Cancels the current recording session without processing any audio.
    /// Used when the user taps the text field while listening, signalling they prefer to type.
    func chatCancelListening() async {
        await cancelActiveListening(reason: "userSwitchedToText", logMessage: "listeningCancelled — user switched to text input")
    }

    private func cancelActiveListening(reason: String, logMessage: String) async {
        guard chatFlowState == .listening else { return }
        cancelAutoRelisten(reason: reason)
        cancelMaxRecordingTimer()
        _ = cancelFollowUpNoSpeechTimer(reason: reason)
        speechService.onPartialTranscript = nil
        speechService.onSpeechDetected = nil
        await speechService.cancelForReset()
        isStoppingListening = false
        chatFlowState = .idle
        chatDraftText = ""
        Self.log.info("[VoiceChat] \(logMessage, privacy: .public)")
    }

    func chatTextEditingChanged(isFocused: Bool) {
        isTextEditing = isFocused
        if isFocused {
            cancelAutoRelisten(reason: "textEditing")
        }
    }

    // MARK: - Mic tap entry point (unchanged)

    func chatMicrophoneTapped() {
        cancelAutoRelisten(reason: "micTapped")
        switch chatFlowState {
        case .idle, .success, .error:
            guard assistantAccessAllowed(logContext: "manualMicTap") else {
                Self.log.info("[VoiceChat] voiceStartBlockedByPaywall")
                Task { await handleAssistantAccessBlocked(context: "manualMicTap") }
                return
            }
            Task { await chatBeginListening(startReason: "manual") }
        case .listening:
            Self.log.info("[VoiceChat] manualStopTriggered")
            Task { await chatFinalizeListening(stopReason: .manual) }
        case .processing, .conflictPending, .deletePending, .editConfirmationPending, .disambiguating:
            break
        }
    }

    // MARK: - Max-duration safety net

    private static let maxRecordingNanoseconds: UInt64 = 60_000_000_000

    private func startMaxRecordingTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxRecordingNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.chatFlowState == .listening else { return }
            Self.log.info("[VoiceChat] maxDurationStopTriggered maxSeconds=60")
            await self.chatFinalizeListening(stopReason: .maxTimeout)
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
            isAppActive = false
            cancelAutoRelisten(reason: "sceneInactive")
            _ = cancelFollowUpNoSpeechTimer(reason: "sceneInactive")
            cancelAllProcessingStatusHints()
            if chatFlowState == .listening {
                Task { await cancelActiveListening(reason: "sceneInactive", logMessage: "listeningCancelled — scene inactive") }
            }
        } else if phase == .active {
            isAppActive = true
            if chatFlowState == .processing {
                scheduleProcessingStatusSequence()
            }
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
    private func emitAssistantResponse(
        _ text: String,
        nextState: VoiceFlowState,
        stream: Bool,
        showsImportantPriorityBadge: Bool = false
    ) {
        if stream, !text.isEmpty {
            if let slot = pendingAssistantSlotId, chatMessages.contains(where: { $0.id == slot && $0.role == .assistant }) {
                pendingAssistantSlotId = nil
                if let idx = chatMessages.firstIndex(where: { $0.id == slot }) {
                    chatMessages[idx].showsImportantPriorityBadge = showsImportantPriorityBadge
                }
                startStreamingText(into: slot, fullText: text) { [weak self] in
                    guard let self else { return }
                    self.chatFlowState = nextState
                    self.scheduleFollowUpListeningAfterSuccessIfNeeded()
                }
            } else {
                let slot = UUID()
                chatMessages.append(ChatMessage(
                    id: slot,
                    role: .assistant,
                    text: "",
                    showsImportantPriorityBadge: showsImportantPriorityBadge
                ))
                startStreamingText(into: slot, fullText: text) { [weak self] in
                    guard let self else { return }
                    self.chatFlowState = nextState
                    self.scheduleFollowUpListeningAfterSuccessIfNeeded()
                }
            }
        } else {
            // Non-stream path replaces the bubble in one step; must invalidate any in-progress stream first.
            cancelStreamReveal()
            if let slot = pendingAssistantSlotId, let idx = chatMessages.firstIndex(where: { $0.id == slot && $0.role == .assistant }) {
                pendingAssistantSlotId = nil
                chatMessages[idx].text = text
                chatMessages[idx].showsImportantPriorityBadge = showsImportantPriorityBadge
            } else {
                chatMessages.append(ChatMessage(
                    role: .assistant,
                    text: text,
                    showsImportantPriorityBadge: showsImportantPriorityBadge
                ))
            }
            chatFlowState = nextState
            scheduleFollowUpListeningAfterSuccessIfNeeded()
        }
    }

    // MARK: - Follow-up listening window

    private static let autoRelistenDelayNanoseconds: UInt64 = 500_000_000
    private static let followUpNoSpeechNanoseconds: UInt64 = 7_000_000_000

    private func scheduleFollowUpListeningAfterSuccessIfNeeded() {
        guard chatFlowState == .success else { return }
        guard currentSubmitCameFromVoiceDraft else {
            Self.log.info("[VoiceChat] autoRelistenSkipped reason=notVoiceCommand")
            return
        }
        currentSubmitCameFromVoiceDraft = false
        guard voiceFollowUpAutoStartsRemaining > 0 else {
            Self.log.info("[VoiceChat] autoRelistenSkipped reason=followUpWindowConsumed")
            return
        }
        voiceFollowUpAutoStartsRemaining -= 1
        scheduleAutoRelisten(reason: "commandCompleted")
    }

    private func scheduleAutoRelisten(reason: String) {
        if let skip = autoRelistenSkipReason() {
            Self.log.info("[VoiceChat] autoRelistenSkipped reason=\(skip, privacy: .public) trigger=\(reason, privacy: .public)")
            return
        }
        cancelAutoRelisten(reason: "coalesced")
        Self.log.info("[VoiceChat] autoRelistenScheduled reason=\(reason, privacy: .public) delayMs=500")
        autoRelistenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoRelistenDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let skip = self.autoRelistenSkipReason() {
                Self.log.info("[VoiceChat] autoRelistenSkipped reason=\(skip, privacy: .public) trigger=delayedStart")
                self.autoRelistenTask = nil
                return
            }
            Self.log.info("[VoiceChat] autoRelistenStarted")
            self.autoRelistenTask = nil
            await self.chatBeginListening(startReason: "autoRelisten")
        }
    }

    private func cancelAutoRelisten(reason: String) {
        guard autoRelistenTask != nil else { return }
        autoRelistenTask?.cancel()
        autoRelistenTask = nil
        Self.log.info("[VoiceChat] autoRelistenCancelled reason=\(reason, privacy: .public)")
    }

    private func startFollowUpNoSpeechTimerIfNeeded(startReason: String) {
        _ = cancelFollowUpNoSpeechTimer(reason: "rescheduled")
        guard startReason == "autoRelisten" else { return }
        Self.log.info("[VoiceChat] followUpWindowStarted timeoutMs=7000")
        followUpNoSpeechTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.followUpNoSpeechNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.followUpNoSpeechTask = nil
            if self.chatFlowState == .listening {
                Self.log.info("[VoiceChat] followUpWindowExpired ignored reason=alreadyListening")
                return
            }
            if self.followUpSpeechDetected {
                Self.log.info("[VoiceChat] followUpWindowExpired ignored reason=speechAlreadyDetected")
                return
            }
            Self.log.info("[VoiceChat] followUpWindowExpired reason=noSpeech")
        }
    }

    @discardableResult
    private func cancelFollowUpNoSpeechTimer(reason: String) -> Bool {
        guard followUpNoSpeechTask != nil else { return false }
        followUpNoSpeechTask?.cancel()
        followUpNoSpeechTask = nil
        Self.log.info("[VoiceChat] followUpWindowCancelled reason=\(reason, privacy: .public)")
        return true
    }

    private func autoRelistenSkipReason() -> String? {
        guard canUseAssistant else { return "paywallLocked" }
        guard isChatSheetPresented else { return "sheetNotPresented" }
        guard isAppActive else { return "appInactive" }
        guard !isTextEditing else { return "textEditing" }
        guard pendingAssistantSlotId == nil else { return "assistantSlotPending" }
        guard pendingConflictCommand == nil else { return "conflictPending" }
        guard pendingDeleteTask == nil else { return "deletePending" }
        guard confirmationCandidate == nil else { return "editConfirmationPending" }
        guard pendingEditAction == nil else { return "editPending" }
        guard disambiguationCandidates.isEmpty else { return "disambiguationPending" }

        switch chatFlowState {
        case .idle, .success:
            return nil
        case .listening:
            return "alreadyListening"
        case .processing:
            return "processing"
        case .conflictPending:
            return "conflictPending"
        case .deletePending:
            return "deletePending"
        case .editConfirmationPending:
            return "editConfirmationPending"
        case .disambiguating:
            return "disambiguationPending"
        case .error:
            return "errorState"
        }
    }

    // MARK: - Begin listening

    func chatBeginListening(startReason: String = "manual") async {
        guard assistantAccessAllowed(logContext: "beginListening:\(startReason)") else {
            Self.log.info("[VoiceChat] voiceStartBlockedByPaywall")
            await handleAssistantAccessBlocked(context: "beginListening")
            return
        }
        guard chatFlowState == .idle || chatFlowState == .success || chatFlowState == .error else {
            Self.log.info("[VoiceChat] listenStartSkipped reason=stateNotReady state=\(String(describing: self.chatFlowState), privacy: .public) startReason=\(startReason, privacy: .public)")
            return
        }
        guard isChatSheetPresented else {
            Self.log.info("[VoiceChat] listenStartSkipped reason=sheetNotPresented startReason=\(startReason, privacy: .public)")
            return
        }
        guard isAppActive else {
            Self.log.info("[VoiceChat] listenStartSkipped reason=appInactive startReason=\(startReason, privacy: .public)")
            return
        }

        voiceDraftErrorMessage = nil
        isStoppingListening = false
        cancelMaxRecordingTimer()
        currentListeningIsAutoFollowUp = startReason == "autoRelisten"
        followUpSpeechDetected = false

        let msgs = uiLanguage.speechMessages
        let wallStart = Date().timeIntervalSince1970
        Self.log.info("[VoiceChat] recordingStarted recordingStartTime=\(wallStart, privacy: .public) startReason=\(startReason, privacy: .public) appUILanguage=\(self.uiLanguage.rawValue, privacy: .public)")

        // Keep Apple partials internal only; multilingual chat displays the backend transcript after stop.
        speechService.onPartialTranscript = { [weak self] text in
            guard let self, self.chatFlowState == .listening else { return }
            self.followUpSpeechDetected = true
            self.cancelFollowUpNoSpeechTimer(reason: "speechDetected")
            Self.log.info("[VoiceChat] localPartialReceived chars=\(text.count, privacy: .public) hiddenFromUI=true")
        }
        speechService.onSpeechDetected = { [weak self] in
            guard let self else { return }
            self.followUpSpeechDetected = true
            self.cancelFollowUpNoSpeechTimer(reason: "speechDetected")
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
            autoStopBehavior: .enabled,
            onAutoStop: { [weak self] in
                guard let self, self.chatFlowState == .listening else { return }
                Self.log.info("[VoiceChat] autoStopTriggered reason=silenceMeteringElapsed")
                Task { await self.chatFinalizeListening(stopReason: .autoSilence) }
            }
        )

        if let startError {
            emitAssistantResponse(startError, nextState: .error, stream: false)
            return
        }

        chatFlowState = .listening
        startMaxRecordingTimer()
        let cancelledFollowUpWindow = cancelFollowUpNoSpeechTimer(reason: "recordingStarted")
        if startReason == "autoRelisten", !cancelledFollowUpWindow {
            Self.log.info("[VoiceChat] followUpWindowCancelled reason=recordingStarted")
        }
        Self.log.info("[VoiceChat] listening active — auto-stop only after ~3s below-threshold hangover + ~1.5s quiet (~4.5s total after last speech); min recording 2s before auto-stop; max 60s; tap mic to stop")
        Self.log.info("[VoiceChat] recordingSessionParams note=see SpeechRecognizerService silence metering")
    }

    // MARK: - Finalize listening (orchestrator)

    func chatFinalizeListening(stopReason: VoiceStopReason = .manual) async {
        guard assistantAccessAllowed(logContext: "finalizeListening") else {
            await handleAssistantAccessBlocked(context: "finalizeListening")
            return
        }
        guard !isStoppingListening else {
            Self.log.info("[VoiceChat] stopIgnored reason=alreadyStopping stopReason=\(stopReason.rawValue, privacy: .public)")
            return
        }
        guard chatFlowState == .listening else {
            Self.log.info("[VoiceChat] stopIgnored reason=stateNotListening state=\(String(describing: self.chatFlowState), privacy: .public) stopReason=\(stopReason.rawValue, privacy: .public)")
            return
        }
        isStoppingListening = true
        cancelMaxRecordingTimer()
        cancelFollowUpNoSpeechTimer(reason: "finalizeListening")
        chatFlowState = .processing
        chatDraftText = ""

        let pipelineT0 = CFAbsoluteTimeGetCurrent()
        Self.log.info("[VoiceChat] recordingStopped enteringProcessing stopReason=\(stopReason.rawValue, privacy: .public)")
        let stopT0 = CFAbsoluteTimeGetCurrent()
        let captureOutcome = await speechService.stopListening(waitForLocalFinal: false)
        Self.log.info("[VoiceChat] latency stopListening ms=\(latencyMs(since: stopT0), privacy: .public)")
        Self.log.info("[VoiceChat] transcriptionStarted stopReason=\(stopReason.rawValue, privacy: .public)")
        let strings = uiLanguage.strings
        let speechMsgs = uiLanguage.speechMessages

        switch captureOutcome {
        case .failure(let error):
            handleCaptureFailure(error, strings: strings, speechMsgs: speechMsgs)
            Self.log.info("[VoiceChat] latency chatFinalizeListening totalMs=\(latencyMs(since: pipelineT0), privacy: .public) outcome=failure")

        case .success(let captureResult):
            Self.log.info("[VoiceChat] captureSuccess localTranscript=\(captureResult.transcript, privacy: .public) confidence=\(String(describing: captureResult.confidence), privacy: .public) duration=\(captureResult.duration, privacy: .public)s audioURL=\(captureResult.audioURL?.path ?? "nil", privacy: .public)")
            Self.log.info("[VoiceChat] finalAudioDuration=\(captureResult.duration, privacy: .public)s stopReason=\(stopReason.rawValue, privacy: .public)")
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
            Self.log.info("[VoiceChat] captureFailure emptyOrTooShort — returning to idle without user-visible error")
            voiceDraftErrorMessage = nil
            chatFlowState = .idle
            parsedCommand = nil
            return
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
        guard assistantAccessAllowed(logContext: "cloudTranscription") else {
            Self.log.info("[VoiceChat] cloudTranscriptionBlockedByPaywall")
            await handleAssistantAccessBlocked(context: "cloudTranscription")
            return
        }
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
                Self.log.info("[VoiceChat] cloudTranscriptionEmpty — returning to idle without user-visible error")
                voiceDraftErrorMessage = nil
                chatFlowState = .idle
                parsedCommand = nil
                return
            case MultilingualTranscriptionError.networkError(let u, let rid):
                requestIdForLog = rid.uuidString
                rootCause = "networkError — \(u.localizedDescription)"
                userMessage = noInternetConnectionMessage(strings: strings)
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
            Self.log.info("[VoiceChat] emptyTranscript — returning to idle without user-visible error")
            voiceDraftErrorMessage = nil
            chatFlowState = .idle
            return
        }
        Self.log.info("[VoiceChat] transcriptionCompleted transcriptChars=\(trimmed.count, privacy: .public) next=idleAwaitingUserSend")
        Self.log.info("[VoiceChat] transcriptDeliveredToInputField=\(trimmed, privacy: .public)")
        voiceDraftErrorMessage = nil
        voiceDraftAwaitingSubmit = true
        voiceFollowUpAutoStartsRemaining = currentListeningIsAutoFollowUp ? 0 : 1
        currentListeningIsAutoFollowUp = false
        pendingVoiceTranscript = trimmed
        chatFlowState = .idle
    }

    // MARK: - Parse + route to task actions (largely unchanged)

    func applyChatParse(transcript: String) async {
        guard assistantAccessAllowed(logContext: "applyChatParse") else {
            await handleAssistantAccessBlocked(context: "applyChatParse")
            return
        }
        guard ensureAIParseAllowed() else {
            handlePaywallBlockedParse()
            return
        }

        Self.log.info("[VoiceChat] commandInterpretStart")
        do {
            let interpretation = try await interpretChatCommand(transcript)
            await handleCommandInterpretation(interpretation, transcript: transcript)
            return
        } catch {
            Self.log.error("[VoiceChat] commandInterpretFallbackToParse error=\(String(describing: error), privacy: .public)")
        }

        Self.log.info("[VoiceChat] parseStarted fallback=true")

        Self.log.info("[VoiceChat] parse input appUILanguage=\(self.uiLanguage.rawValue, privacy: .public) activeTaskID=\(self.lastActiveChatTaskContext?.taskID.uuidString ?? "nil", privacy: .public) transcript=\(transcript, privacy: .public)")
        let command = await parsingCoordinator.parse(
            text: transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            activeTaskContext: lastActiveChatTaskContext
        )
        Self.log.info("[VoiceChat] parse outcome backendIntentType=\(String(describing: command.actionType), privacy: .public) target.reference_type=\(String(describing: command.targetReferenceType), privacy: .public) target.task_id=\(command.targetTaskID?.uuidString ?? "nil", privacy: .public) parserSource=\(String(describing: command.parserSource), privacy: .public) title=\(command.title, privacy: .public)")
        parsedCommand = command

        if shouldRejectParsedCommand(command) {
            handleUnclearParsedCommand(command)
            return
        }

        // ── Route edit intents ────────────────────────────────────────────────
        switch command.actionType {
        case .deleteTask:
            await handleDeleteIntent(command)
            return
        case .rescheduleTask:
            await handleRescheduleIntent(command)
            return
        case .appendToTask:
            await handleAppendIntent(command)
            return
        case .updateTaskTitle:
            await handleUpdateTitleIntent(command)
            return
        case .updateRecurrence:
            await handleUpdateRecurrenceIntent(command)
            return
        case .updateAlertStyle:
            await handleUpdateAlertStyleIntent(command)
            return
        default:
            break
        }

        // ── Create: conflict check then save ─────────────────────────────────
        guard command.actionType == .reminder || command.actionType == .calendarEvent else {
            Self.log.info("[VoiceChat] conflictDetectionSkipped reason=nonCreateIntent actionType=\(String(describing: command.actionType), privacy: .public)")
            handleUnclearParsedCommand(command)
            return
        }
        if lastActiveChatTaskContext != nil {
            Self.log.info("[VoiceChat] activeContextIgnored reason=backendReturnedCreate finalFrontendAction=createTask activeTaskID=\(self.lastActiveChatTaskContext?.taskID.uuidString ?? "nil", privacy: .public) actionType=\(String(describing: command.actionType), privacy: .public) target.reference_type=\(String(describing: command.targetReferenceType), privacy: .public) text=\(transcript, privacy: .public)")
        }
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

    private func shouldRejectParsedCommand(_ command: ParsedCommand) -> Bool {
        if command.actionType == .unknown || command.parserSource == .unknown {
            Self.log.info("[VoiceChat] parseRejected reason=unknown actionType=\(String(describing: command.actionType), privacy: .public) parserSource=\(String(describing: command.parserSource), privacy: .public)")
            return true
        }
        if currentSubmitCameFromVoiceDraft, command.parserSource != .llm {
            Self.log.info("[VoiceChat] parseRejected reason=voiceRequiresBackend parserSource=\(String(describing: command.parserSource), privacy: .public)")
            return true
        }
        if command.parserSource == .llm, let confidence = command.confidence, confidence < 0.45 {
            Self.log.info("[VoiceChat] parseRejected reason=lowConfidence confidence=\(confidence, privacy: .public)")
            return true
        }
        return false
    }

    private func handleUnclearParsedCommand(_ command: ParsedCommand) {
        let wasVoiceDraft = currentSubmitCameFromVoiceDraft
        parsedCommand = nil
        currentSubmitCameFromVoiceDraft = false
        voiceFollowUpAutoStartsRemaining = 0
        let now = Date()
        guard now.timeIntervalSince(lastUnclearFeedbackAt) > 8 else {
            Self.log.info("[VoiceChat] unclearFeedbackThrottled")
            removePendingAssistantSlotIfEmpty()
            chatFlowState = .idle
            return
        }
        lastUnclearFeedbackAt = now
        let message = wasVoiceDraft && command.parserSource != .llm
            ? noInternetConnectionMessage(strings: uiLanguage.strings)
            : unclearCommandMessage()
        emitAssistantResponse(message, nextState: .error, stream: false)
    }

    private func ensureAIParseAllowed() -> Bool {
        guard let sm = subscriptionManager else { return true }
        #if DEBUG
        print("[PaywallGate] pre-parse isSubscribed=\(sm.isPremium) freeUsage=\(sm.freeAIParseSuccessCount)/\(SubscriptionConfig.freeAIParseAllowance)")
        #endif
        if sm.canUseAssistant { return true }
        #if DEBUG
        print("[PaywallGate] parse blocked — presenting paywall (free tier exhausted or not subscribed)")
        #endif
        NotificationCenter.default.post(name: .chatTaskPresentPaywall, object: nil)
        return false
    }

    private func handlePaywallBlockedParse() {
        Self.log.info("[PaywallGate] paywallBlockedParse — AI parse not started")
        cancelAutoRelisten(reason: "paywallLocked")
        cancelMaxRecordingTimer()
        _ = cancelFollowUpNoSpeechTimer(reason: "paywallLocked")
        removePendingAssistantSlotIfEmpty()
        chatFlowState = .idle
        currentSubmitCameFromVoiceDraft = false
        voiceFollowUpAutoStartsRemaining = 0
        pendingAssistantSlotId = nil
        parsedCommand = nil
    }

    private func recordFreeAIUsageIfNeeded(_ command: ParsedCommand?) {
        guard let command, command.parserSource == .llm else { return }
        recordSuccessfulAssistantUseIfNeeded()
    }

    private func recordSuccessfulAssistantUseIfNeeded() {
        guard let subscriptionManager else { return }
        subscriptionManager.recordSuccessfulFreeAIParseIfNeeded()
        guard !subscriptionManager.canUseAssistant else { return }
        Self.log.info("[PaywallGate] assistantLimitReachedAfterSuccessfulUse")
        Task { await handleAssistantAccessBlocked(context: "freeLimitReachedAfterSuccess") }
    }

    /// After an AI parse path has visibly persisted a task change (create/update/delete).
    private func recordSuccessfulAIActionForAppReview() {
        ReviewPromptManager.shared.recordSuccessfulAIAction()
    }

    private func unclearCommandMessage() -> String {
        if uiLanguage == .en {
            return "Didn’t understand that — try something like:\n“Remind me in 10 minutes to drink water”"
        }
        return uiLanguage.strings.chatTryRemind
    }

    private func noInternetConnectionMessage(strings: AppStrings) -> String {
        uiLanguage == .en ? "No internet connection" : strings.chatErrorOffline
    }

    private func removePendingAssistantSlotIfEmpty() {
        guard let slot = pendingAssistantSlotId,
              let idx = chatMessages.firstIndex(where: { $0.id == slot && $0.role == .assistant && $0.text.isEmpty })
        else {
            pendingAssistantSlotId = nil
            return
        }
        chatMessages.remove(at: idx)
        pendingAssistantSlotId = nil
    }

    private func interpretChatCommand(_ transcript: String) async throws -> CommandInterpretResponse {
        let requestId = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let candidates = commandCandidateTasks()
        Self.log.info("[VoiceChat] candidateTasksBuilt count=\(candidates.count, privacy: .public)")
        let request = CommandInterpretRequest(
            text: transcript,
            now: formatter.string(from: Date()),
            timezone: TimeZone.current.identifier,
            locale: uiLanguage.uiLocaleIdentifier,
            activeTask: activeInterpretTaskSnapshot(),
            candidateTasks: candidates.map(commandTaskSnapshot),
            requestID: requestId.uuidString
        )
        return try await commandInterpreter.interpret(request)
    }

    private func handleCommandInterpretation(_ result: CommandInterpretResponse, transcript: String) async {
        Self.log.info("[VoiceChat] commandInterpretResult action=\(result.actionType ?? "nil", privacy: .public) confidence=\(result.confidence, privacy: .public) confirmation=\(result.confirmationKind ?? "nil", privacy: .public) actionsCount=\(result.actions?.count ?? 0, privacy: .public)")
        let containsClarificationAction = result.actions?.contains {
            $0.requiresConfirmation && $0.confirmationKind == "clarify"
        } ?? false
        if result.requiresConfirmation, result.confirmationKind == "clarify" || containsClarificationAction {
            emitAssistantResponse(result.assistantMessage ?? unclearCommandMessage(), nextState: .error, stream: false)
            Self.log.info("[VoiceChat] confirmationShown kind=clarify")
            return
        }
        let actions = result.multiActions
        guard !actions.isEmpty else {
            Self.log.info("[VoiceChat] commandInterpretSingleActionFallbackToOriginalParse")
            await runOriginalParsePipeline(transcript: transcript)
            return
        }
        await executeInterpretedActions(actions, overallMessage: result.assistantMessage, transcript: transcript)
    }

    private func executeInterpretedActions(_ actions: [CommandInterpretResponse.Action], overallMessage: String?, transcript: String) async {
        guard !actions.isEmpty else { return }
        if actions.contains(where: { $0.requiresConfirmation }) {
            emitAssistantResponse(overallMessage ?? "Please confirm the requested changes.", nextState: .error, stream: false)
            Self.log.info("[VoiceChat] confirmationShown kind=multi_action")
            return
        }
        Self.log.info("[VoiceChat] multiActionExecutionStarted count=\(actions.count, privacy: .public)")
        Self.log.info("[VoiceChat] actionsReceived count=\(actions.count, privacy: .public)")
        Self.log.info("[VoiceChat] multiActionSummaryStarted count=\(actions.count, privacy: .public)")
        var failedIndexes: [Int] = []
        var summaries: [String] = []
        var failedDescriptions: [String] = []
        for (index, action) in actions.enumerated() {
            let single = CommandInterpretResponse(action: action, assistantMessage: overallMessage)
            Self.log.info("[VoiceChat] executingAction index=\(index, privacy: .public) type=\(action.actionType ?? "nil", privacy: .public)")
            if let result = await executeInterpretedCommand(
                single,
                selectedTaskOverride: nil,
                transcript: transcript,
                emitResponse: false,
                countUsage: false
            ) {
                summaries.append(result.summary)
                Self.log.info("[VoiceChat] actionSucceeded index=\(index, privacy: .public)")
                Self.log.info("[VoiceChat] actionResultSummary index=\(index, privacy: .public) summary=\(result.summary, privacy: .public)")
            } else {
                failedIndexes.append(index)
                failedDescriptions.append(failureDescription(for: action))
                Self.log.info("[VoiceChat] actionFailed index=\(index, privacy: .public)")
                Self.log.info("[VoiceChat] multiActionPartFailed index=\(index, privacy: .public) action=\(action.actionType ?? "nil", privacy: .public)")
            }
        }
        Self.log.info("[VoiceChat] executedActionsCount=\(summaries.count, privacy: .public)")
        if failedIndexes.isEmpty {
            let final = combinedMultiActionSummary(summaries)
            emitAssistantResponse(final, nextState: .success, stream: true)
            recordSuccessfulAssistantUseIfNeeded()
            Self.log.info("[VoiceChat] multiActionSummaryFinal text=\(final, privacy: .public)")
            Self.log.info("[VoiceChat] multiActionExecutionCompleted count=\(actions.count, privacy: .public)")
        } else if failedIndexes.count == actions.count {
            emitAssistantResponse(unclearCommandMessage(), nextState: .error, stream: false)
            Self.log.info("[VoiceChat] multiActionPartialFailure successCount=0 failedCount=\(failedIndexes.count, privacy: .public)")
            Self.log.info("[VoiceChat] multiActionExecutionCompleted failedAll=true")
        } else {
            let final = partialMultiActionSummary(summaries: summaries, failedDescriptions: failedDescriptions)
            emitAssistantResponse(final, nextState: .success, stream: true)
            recordSuccessfulAssistantUseIfNeeded()
            Self.log.info("[VoiceChat] multiActionSummaryFinal text=\(final, privacy: .public)")
            Self.log.info("[VoiceChat] multiActionPartialFailure successCount=\(summaries.count, privacy: .public) failedCount=\(failedIndexes.count, privacy: .public)")
            Self.log.info("[VoiceChat] multiActionExecutionCompleted partialFailures=\(failedIndexes.count, privacy: .public)")
        }
    }

    private func combinedMultiActionSummary(_ summaries: [String]) -> String {
        let cleaned = summaries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "Done." }
        if cleaned.count == 1 {
            return "Done — \(cleaned[0])."
        }
        if cleaned.count == 2 {
            return "Done — \(cleaned[0]) and \(cleaned[1])."
        }
        let lines = cleaned.enumerated().map { index, summary in
            "\(index + 1). \(summary.prefix(1).uppercased())\(summary.dropFirst())"
        }
        return "Done — I completed \(cleaned.count) updates:\n" + lines.joined(separator: "\n")
    }

    private func partialMultiActionSummary(summaries: [String], failedDescriptions: [String]) -> String {
        let base = combinedMultiActionSummary(summaries)
        let trimmedBase = base.hasSuffix(".") ? String(base.dropLast()) : base
        guard !failedDescriptions.isEmpty else {
            return "\(trimmedBase), but couldn't complete the rest."
        }
        if failedDescriptions.count == 1 {
            return "\(trimmedBase), but couldn't \(failedDescriptions[0])."
        }
        return "\(trimmedBase), but couldn't complete \(failedDescriptions.count) other actions."
    }

    private func failureDescription(for action: CommandInterpretResponse.Action) -> String {
        switch action.actionType {
        case "createReminder":
            return "add the reminder"
        case "createEvent":
            return "add the event"
        case "rescheduleTask":
            return "move the task"
        case "appendToTask":
            return "add the note"
        case "deleteTask":
            return "delete the task"
        case "renameTask":
            return "rename the task"
        case "updateRecurrence":
            return "update the repeat schedule"
        case "updateAlertStyle":
            return "update the alert"
        default:
            return "complete one action"
        }
    }

    private func interpretedCreateTimeSuffix(for command: ParsedCommand) -> String {
        guard let date = command.reminderDate ?? command.startDate else { return "" }
        return " at \(shortTimeFormatter.string(from: date))"
    }

    private func runOriginalParsePipeline(transcript: String) async {
        Self.log.info("[VoiceChat] parseStarted fallback=true")

        Self.log.info("[VoiceChat] parse input appUILanguage=\(self.uiLanguage.rawValue, privacy: .public) activeTaskID=\(self.lastActiveChatTaskContext?.taskID.uuidString ?? "nil", privacy: .public) transcript=\(transcript, privacy: .public)")
        let command = await parsingCoordinator.parse(
            text: transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            activeTaskContext: lastActiveChatTaskContext
        )
        Self.log.info("[VoiceChat] parse outcome backendIntentType=\(String(describing: command.actionType), privacy: .public) target.reference_type=\(String(describing: command.targetReferenceType), privacy: .public) target.task_id=\(command.targetTaskID?.uuidString ?? "nil", privacy: .public) parserSource=\(String(describing: command.parserSource), privacy: .public) title=\(command.title, privacy: .public)")
        parsedCommand = command

        if shouldRejectParsedCommand(command) {
            handleUnclearParsedCommand(command)
            return
        }

        switch command.actionType {
        case .deleteTask:
            await handleDeleteIntent(command)
            return
        case .rescheduleTask:
            await handleRescheduleIntent(command)
            return
        case .appendToTask:
            await handleAppendIntent(command)
            return
        case .updateTaskTitle:
            await handleUpdateTitleIntent(command)
            return
        case .updateRecurrence:
            await handleUpdateRecurrenceIntent(command)
            return
        case .updateAlertStyle:
            await handleUpdateAlertStyleIntent(command)
            return
        default:
            break
        }

        guard command.actionType == .reminder || command.actionType == .calendarEvent else {
            emitAssistantResponse(unclearCommandMessage(), nextState: .error, stream: false)
            return
        }
        commitSave(command: command)
    }

    private func handleLegacyInterpretedCommand(_ result: CommandInterpretResponse, transcript: String) async {
        guard result.actionType != nil else {
            emitAssistantResponse(result.assistantMessage ?? unclearCommandMessage(), nextState: .error, stream: false)
            return
        }
        if result.requiresConfirmation {
            showInterpretedConfirmation(result, transcript: transcript)
            return
        }
        await executeInterpretedCommand(result, selectedTaskOverride: nil, transcript: transcript)
    }

    private func showInterpretedConfirmation(_ result: CommandInterpretResponse, transcript: String) {
        switch result.confirmationKind {
        case "choose_candidate":
            let tasks = tasksForInterpretedCandidateIDs(result.target?.candidateIDs ?? [])
            guard !tasks.isEmpty else {
                emitAssistantResponse(result.assistantMessage ?? noTaskMatchMessage(strings: uiLanguage.strings), nextState: .error, stream: false)
                return
            }
            pendingConfirmationPayload = .interpreted(result, transcript: transcript)
            disambiguationCandidates = tasks
            emitAssistantResponse(result.assistantMessage ?? editDisambiguationMessage(), nextState: .disambiguating, stream: true)
            Self.log.info("[VoiceChat] confirmationShown kind=choose_candidate")
        case "clarify":
            emitAssistantResponse(result.assistantMessage ?? unclearCommandMessage(), nextState: .error, stream: false)
            Self.log.info("[VoiceChat] confirmationShown kind=clarify")
        default:
            guard let task = taskForInterpretedTarget(result) else {
                emitAssistantResponse(result.assistantMessage ?? noTaskMatchMessage(strings: uiLanguage.strings), nextState: .error, stream: false)
                return
            }
            confirmationCandidate = task
            pendingConfirmationPayload = .interpreted(result, transcript: transcript)
            emitAssistantResponse(result.assistantMessage ?? editConfirmationMessage(for: task), nextState: .editConfirmationPending, stream: true)
            Self.log.info("[VoiceChat] confirmationShown kind=confirm_action")
        }
    }

    @discardableResult
    private func executeInterpretedCommand(_ result: CommandInterpretResponse, selectedTaskOverride: TaskItem?, transcript: String, emitResponse: Bool = true, countUsage: Bool = true) async -> InterpretedActionExecutionResult? {
        guard let action = result.actionType else { return nil }
        Self.log.info("[VoiceChat] commandExecutionStarted action=\(action, privacy: .public)")
        var summary: String?
        switch action {
        case "createReminder", "createEvent":
            guard let command = parsedCommand(from: result) else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            commitCreateWithConflictCheck(command, emitResponse: emitResponse, countUsage: countUsage)
            let timeSuffix = interpretedCreateTimeSuffix(for: command)
            summary = action == "createEvent"
                ? "added event '\(command.title)'\(timeSuffix)"
                : "added reminder '\(command.title)'\(timeSuffix)"
        case "rescheduleTask":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result),
                  let raw = result.edit?.newScheduledAt,
                  let newDate = parseInterpretedDate(raw) else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            applyReschedule(task: task, newDate: newDate, strings: uiLanguage.strings, usageCommand: nil, emitResponse: emitResponse, countUsage: countUsage)
            summary = "moved '\(task.title)' to \(shortTimeFormatter.string(from: newDate))"
            if let style = alertStyle(from: result.edit?.alertStyle) {
                applyAlertStyle(task: task, style: style, strings: uiLanguage.strings, usageCommand: nil, emitResponse: false, countUsage: false)
            }
        case "renameTask":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result),
                  let newTitle = result.edit?.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newTitle.isEmpty else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            guard isExplicitRenameRequest(transcript) else {
                blockInterpretedExecution(reason: "renameWithoutExplicitRequest", emitResponse: emitResponse)
                return nil
            }
            let oldTitle = task.title
            applyRename(task: task, newTitle: newTitle, strings: uiLanguage.strings, usageCommand: nil, emitResponse: emitResponse, countUsage: countUsage)
            summary = "renamed '\(oldTitle)' to '\(newTitle)'"
            if let style = alertStyle(from: result.edit?.alertStyle) {
                applyAlertStyle(task: task, style: style, strings: uiLanguage.strings, usageCommand: nil, emitResponse: false, countUsage: false)
            }
        case "appendToTask":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result),
                  let text = result.edit?.appendText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            applyAppend(task: task, text: text, strings: uiLanguage.strings, usageCommand: nil, emitResponse: emitResponse, countUsage: countUsage)
            summary = "added a note: '\(text)'"
            if let style = alertStyle(from: result.edit?.alertStyle) {
                applyAlertStyle(task: task, style: style, strings: uiLanguage.strings, usageCommand: nil, emitResponse: false, countUsage: false)
            }
        case "deleteTask":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result) else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            let title = task.title
            if emitResponse {
                enterDeleteConfirmation(for: task, strings: uiLanguage.strings, usageCommand: nil)
            } else {
                deleteTaskImmediately(task, usageCommand: nil, emitResponse: false, countUsage: countUsage)
            }
            summary = "deleted '\(title)'"
        case "updateRecurrence":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result),
                  let update = recurrenceUpdate(from: result) else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            applyRecurrenceUpdate(task: task, update: update, strings: uiLanguage.strings, usageCommand: nil, emitResponse: emitResponse, countUsage: countUsage)
            summary = "updated repeat schedule for '\(task.title)'"
            if let style = alertStyle(from: result.edit?.alertStyle) {
                applyAlertStyle(task: task, style: style, strings: uiLanguage.strings, usageCommand: nil, emitResponse: false, countUsage: false)
            }
        case "updateAlertStyle":
            guard let task = selectedTaskOverride ?? taskForInterpretedTarget(result),
                  let style = alertStyle(from: result.edit?.alertStyle) else {
                blockInterpretedExecution(reason: "missingField", emitResponse: emitResponse)
                return nil
            }
            applyAlertStyle(task: task, style: style, strings: uiLanguage.strings, usageCommand: nil, emitResponse: emitResponse, countUsage: countUsage)
            summary = "updated alert for '\(task.title)' to \(style.displayName)"
        default:
            if emitResponse {
                emitAssistantResponse(result.assistantMessage ?? unclearCommandMessage(), nextState: .error, stream: false)
            }
            return nil
        }
        if countUsage && action != "createReminder" && action != "createEvent" {
            recordSuccessfulAssistantUseIfNeeded()
        }
        Self.log.info("[VoiceChat] commandExecutionCompleted action=\(action, privacy: .public)")
        return summary.map(InterpretedActionExecutionResult.init(summary:))
    }

    private func blockInterpretedExecution(reason: String, emitResponse: Bool = true) {
        Self.log.info("[VoiceChat] commandExecutionBlocked reason=\(reason, privacy: .public)")
        if emitResponse {
            emitAssistantResponse(unclearCommandMessage(), nextState: .error, stream: false)
        }
    }

    private func isExplicitRenameRequest(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")
        return compact.contains("改名")
            || compact.contains("名字改成")
            || compact.contains("名称改成")
            || compact.contains("標題改成")
            || compact.contains("标题改成")
            || lower.contains("rename")
            || lower.contains("change the name")
            || lower.contains("change the title")
    }

    // MARK: - Edit intent handlers (unchanged)

    private func handleUpdateTitleIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        let newTitle = command.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newTitle.isEmpty else {
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        await routeResolvedEditTarget(command, editType: .rename(to: newTitle), strings: s) { task, usageCommand in
            applyRename(task: task, newTitle: newTitle, strings: s, usageCommand: usageCommand)
        }
    }

    private func handleDeleteIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        await routeResolvedEditTarget(command, editType: .delete, strings: s) { task, usageCommand in
            Self.log.info("[VoiceChat] deleteIntent — found task title=\(task.title, privacy: .public)")
            enterDeleteConfirmation(for: task, strings: s, usageCommand: usageCommand)
        }
    }

    private func handleRescheduleIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        guard let newDate = command.newScheduledDate else {
            Self.log.warning("[VoiceChat] rescheduleIntent — newScheduledDate is nil")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        let appendText = command.appendText?.trimmingCharacters(in: .whitespacesAndNewlines)
        await routeResolvedEditTarget(command, editType: .reschedule(newDate: newDate), strings: s) { task, usageCommand in
            applyReschedule(task: task, newDate: newDate, strings: s, usageCommand: usageCommand)
            if let appendText, !appendText.isEmpty {
                applyAppend(task: task, text: appendText, strings: s, usageCommand: nil, emitResponse: false, countUsage: false)
            }
        }
    }

    private func handleAppendIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        let text = command.appendText ?? command.title
        guard !text.isEmpty else {
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        await routeResolvedEditTarget(command, editType: .appendNote(text: text), strings: s) { task, usageCommand in
            applyAppend(task: task, text: text, strings: s, usageCommand: usageCommand)
        }
    }

    private func handleUpdateRecurrenceIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        guard let update = command.recurrenceUpdate else {
            Self.log.warning("[VoiceChat] updateRecurrenceIntent — recurrenceUpdate is nil")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        await routeResolvedEditTarget(command, editType: .updateRecurrence(update), strings: s) { task, usageCommand in
            applyRecurrenceUpdate(task: task, update: update, strings: s, usageCommand: usageCommand)
        }
    }

    private func handleUpdateAlertStyleIntent(_ command: ParsedCommand) async {
        let s = uiLanguage.strings
        guard let style = command.alertStyle else {
            Self.log.warning("[VoiceChat] updateAlertStyleIntent — alertStyle is nil")
            emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            return
        }
        await routeResolvedEditTarget(command, editType: .updateAlertStyle(style), strings: s) { task, usageCommand in
            applyAlertStyle(task: task, style: style, strings: s, usageCommand: usageCommand)
        }
    }

    private func routeResolvedEditTarget(
        _ command: ParsedCommand,
        editType: PendingEditType,
        strings s: AppStrings,
        apply: (TaskItem, ParsedCommand?) -> Void
    ) async {
        switch await resolveEditTarget(for: command) {
        case .resolved(let task, let confidence, let reason):
            Self.log.info("[VoiceChat] taskResolveHighConfidence task=\(task.title, privacy: .public) confidence=\(confidence.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
            apply(task, command)
        case .needsConfirmation(let candidate, let reason):
            enterEditConfirmation(candidate: candidate, editType: editType, reason: reason, strings: s, usageCommand: command)
        case .needsDisambiguation(let candidates, let reason):
            Self.log.info("[VoiceChat] taskResolveNeedsDisambiguation count=\(candidates.count, privacy: .public) reason=\(reason, privacy: .public)")
            enterDisambiguation(matches: candidates, editType: editType, strings: s, usageCommand: command)
        case .noMatch(let reason):
            Self.log.info("[VoiceChat] taskResolveNoMatch reason=\(reason, privacy: .public)")
            emitAssistantResponse(noTaskMatchMessage(strings: s), nextState: .error, stream: false)
        }
    }

    // MARK: - Disambiguation (unchanged)

    private static let disambiguationLimit = 5

    private func enterEditConfirmation(candidate: TaskItem, editType: PendingEditType, reason: String, strings s: AppStrings, usageCommand: ParsedCommand) {
        Self.log.info("[VoiceChat] taskResolveNeedsConfirmation candidate=\(candidate.title, privacy: .public) reason=\(reason, privacy: .public)")
        pendingConfirmationUsageCommand = usageCommand
        pendingEditAction = PendingEditAction(type: editType)
        confirmationCandidate = candidate
        emitAssistantResponse(editConfirmationMessage(for: candidate), nextState: .editConfirmationPending, stream: true)
    }

    private func enterDisambiguation(matches: [TaskItem], editType: PendingEditType, strings s: AppStrings, usageCommand: ParsedCommand) {
        if matches.count > Self.disambiguationLimit {
            emitAssistantResponse(s.chatEditAmbiguousTask, nextState: .error, stream: false)
            return
        }
        Self.log.info("[VoiceChat] enterDisambiguation count=\(matches.count, privacy: .public)")
        pendingDisambiguationUsageCommand = usageCommand
        disambiguationCandidates = matches
        pendingEditAction = PendingEditAction(type: editType)
        emitAssistantResponse(editDisambiguationMessage(), nextState: .disambiguating, stream: true)
    }

    func chatConfirmEditCandidate() {
        guard let task = confirmationCandidate else { return }
        if let payload = pendingConfirmationPayload {
            pendingConfirmationPayload = nil
            confirmationCandidate = nil
            Self.log.info("[VoiceChat] confirmationAccepted action=interpreted")
            if case .interpreted(let result, let transcript) = payload {
                Task { await executeInterpretedCommand(result, selectedTaskOverride: task, transcript: transcript) }
                return
            }
        }
        guard let action = pendingEditAction else { return }
        let usageCommand = pendingConfirmationUsageCommand
        pendingConfirmationUsageCommand = nil
        confirmationCandidate = nil
        pendingEditAction = nil
        Self.log.info("[VoiceChat] taskResolveUserConfirmed task=\(task.title, privacy: .public)")
        applyPendingEditAction(action.type, to: task, usageCommand: usageCommand)
    }

    func chatChooseAnotherEditCandidate() {
        if case .interpreted(let result, _) = pendingConfirmationPayload {
            confirmationCandidate = nil
            disambiguationCandidates = commandCandidateTasks().prefix(TaskResolverConfig.disambiguationLimit).map { $0 }
            Self.log.info("[VoiceChat] taskResolveChooseAnother")
            emitAssistantResponse(result.assistantMessage ?? editDisambiguationMessage(), nextState: .disambiguating, stream: true)
            return
        }
        guard let action = pendingEditAction else { return }
        let usageCommand = pendingConfirmationUsageCommand
        pendingConfirmationUsageCommand = nil
        confirmationCandidate = nil
        if disambiguationCandidates.isEmpty, let context = usageCommand {
            disambiguationCandidates = Array(taskTargetCandidates(for: context).prefix(TaskResolverConfig.disambiguationLimit))
        }
        pendingDisambiguationUsageCommand = usageCommand
        pendingEditAction = action
        Self.log.info("[VoiceChat] taskResolveChooseAnother")
        emitAssistantResponse(editDisambiguationMessage(), nextState: .disambiguating, stream: true)
    }

    func chatCancelEditResolution() {
        pendingConfirmationUsageCommand = nil
        pendingDisambiguationUsageCommand = nil
        pendingEditAction = nil
        pendingConfirmationPayload = nil
        confirmationCandidate = nil
        disambiguationCandidates = []
        Self.log.info("[VoiceChat] taskResolveCancelled")
        emitAssistantResponse(uiLanguage == .en ? "Canceled." : "已取消。", nextState: .error, stream: false)
    }

    func chatSelectCandidate(_ task: TaskItem) {
        if case .interpreted(let result, let transcript) = pendingConfirmationPayload {
            pendingConfirmationPayload = nil
            disambiguationCandidates = []
            Self.log.info("[VoiceChat] candidateSelected id=\(task.id.uuidString, privacy: .public)")
            Task { await executeInterpretedCommand(result, selectedTaskOverride: task, transcript: transcript) }
            return
        }
        guard let action = pendingEditAction else { return }
        let usageCommand = pendingDisambiguationUsageCommand
        pendingDisambiguationUsageCommand = nil
        pendingEditAction = nil
        disambiguationCandidates = []
        Self.log.info("[VoiceChat] taskResolveUserSelectedCandidate task=\(task.title, privacy: .public)")
        applyPendingEditAction(action.type, to: task, usageCommand: usageCommand)
    }

    private func applyPendingEditAction(_ editType: PendingEditType, to task: TaskItem, usageCommand: ParsedCommand?) {
        let s = uiLanguage.strings
        switch editType {
        case .delete:
            enterDeleteConfirmation(for: task, strings: s, usageCommand: usageCommand)
        case .reschedule(let newDate):
            applyReschedule(task: task, newDate: newDate, strings: s, usageCommand: usageCommand)
        case .appendNote(let text):
            applyAppend(task: task, text: text, strings: s, usageCommand: usageCommand)
        case .rename(let newTitle):
            applyRename(task: task, newTitle: newTitle, strings: s, usageCommand: usageCommand)
        case .updateRecurrence(let update):
            applyRecurrenceUpdate(task: task, update: update, strings: s, usageCommand: usageCommand)
        case .updateAlertStyle(let style):
            applyAlertStyle(task: task, style: style, strings: s, usageCommand: usageCommand)
        }
    }

    // MARK: - Shared edit operations (unchanged)

    private func enterDeleteConfirmation(for task: TaskItem, strings s: AppStrings, usageCommand: ParsedCommand?) {
        pendingDeleteUsageCommand = usageCommand
        pendingDeleteTask = task
        let prompt = String(format: s.chatDeletePrompt, task.title)
        emitAssistantResponse(prompt, nextState: .deletePending, stream: true)
    }

    @discardableResult
    private func applyReschedule(task: TaskItem, newDate: Date, strings s: AppStrings, usageCommand: ParsedCommand?, emitResponse: Bool = true, countUsage: Bool = true) -> Bool {
        Self.log.info("[VoiceChat] finalFrontendAction=rescheduleTask activeContextUsed=true finalTargetTaskID=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .public) newDate=\(newDate, privacy: .public)")
        task.scheduledDate = newDate
        task.updatedAt = Date()
        try? persistenceContext?.save()
        TaskReminderService.shared.schedule(for: task)
        syncCalendarIfNeeded(for: task)
        if emitResponse {
            let timeStr = shortTimeFormatter.string(from: newDate)
            let msg = String(format: s.chatRescheduleSuccess, task.title, timeStr)
            emitAssistantResponse(msg, nextState: .success, stream: true)
        }
        refreshActiveContext(from: task)
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if persistenceContext != nil {
            recordSuccessfulAIActionForAppReview()
        }
        return true
    }

    @discardableResult
    private func applyAppend(task: TaskItem, text: String, strings s: AppStrings, usageCommand: ParsedCommand?, emitResponse: Bool = true, countUsage: Bool = true) -> Bool {
        Self.log.info("[VoiceChat] finalFrontendAction=appendToTask activeContextUsed=true finalTargetTaskID=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .public)")
        if let existing = task.notes, !existing.isEmpty {
            task.notes = existing + "\n" + text
        } else {
            task.notes = text
        }
        task.updatedAt = Date()
        try? persistenceContext?.save()
        syncCalendarIfNeeded(for: task)
        if emitResponse {
            emitAssistantResponse(String(format: s.chatAppendSuccess, task.title), nextState: .success, stream: true)
        }
        refreshActiveContext(from: task)
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if persistenceContext != nil {
            recordSuccessfulAIActionForAppReview()
        }
        return true
    }

    @discardableResult
    private func applyRename(task: TaskItem, newTitle: String, strings s: AppStrings, usageCommand: ParsedCommand?, emitResponse: Bool = true, countUsage: Bool = true) -> Bool {
        Self.log.info("[VoiceChat] finalFrontendAction=updateTaskTitle activeContextUsed=true finalTargetTaskID=\(task.id.uuidString, privacy: .public) newTitle=\(newTitle, privacy: .public)")
        task.title = newTitle
        task.updatedAt = Date()
        try? persistenceContext?.save()
        syncCalendarIfNeeded(for: task)
        if emitResponse {
            emitAssistantResponse(String(format: s.chatRenameSuccess, newTitle), nextState: .success, stream: true)
        }
        refreshActiveContext(from: task)
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if persistenceContext != nil {
            recordSuccessfulAIActionForAppReview()
        }
        return true
    }

    @discardableResult
    private func applyRecurrenceUpdate(task: TaskItem, update: ParsedRecurrenceUpdate, strings s: AppStrings, usageCommand: ParsedCommand?, emitResponse: Bool = true, countUsage: Bool = true) -> Bool {
        Self.log.info("[VoiceChat] finalFrontendAction=updateRecurrence activeContextPreferred=true finalTargetTaskID=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .public) operation=\(String(describing: update.operation), privacy: .public) weekdays=\(String(describing: update.weekdays), privacy: .public)")

        var weekdays = Set(task.recurrenceWeekdays)
        let updateWeekdays = Set(sanitizedRecurrenceWeekdays(update.weekdays ?? []))
        var shouldClearRecurrence = false

        switch update.operation {
        case .setWeekdays:
            guard !updateWeekdays.isEmpty else {
                if emitResponse {
                    emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
                }
                return false
            }
            weekdays = updateWeekdays
        case .addWeekdays:
            guard !updateWeekdays.isEmpty else {
                if emitResponse {
                    emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
                }
                return false
            }
            weekdays.formUnion(updateWeekdays)
        case .removeWeekdays:
            guard !updateWeekdays.isEmpty else {
                if emitResponse {
                    emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
                }
                return false
            }
            weekdays.subtract(updateWeekdays)
            shouldClearRecurrence = weekdays.isEmpty
        case .setTime:
            break
        case .clearRecurrence:
            shouldClearRecurrence = true
        case .unknown:
            if emitResponse {
                emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            }
            return false
        }

        if shouldClearRecurrence {
            clearRecurrence(on: task)
            task.updatedAt = Date()
            try? persistenceContext?.save()
            TaskReminderService.shared.schedule(for: task)
            syncCalendarIfNeeded(for: task)
            if emitResponse {
                emitAssistantResponse("Removed repeat schedule for \(task.title).", nextState: .success, stream: true)
            }
            refreshActiveContext(from: task)
            if countUsage {
                recordFreeAIUsageIfNeeded(usageCommand)
            }
            if persistenceContext != nil {
                recordSuccessfulAIActionForAppReview()
            }
            return true
        }

        let sortedWeekdays = Array(weekdays).filter { (1...7).contains($0) }.sorted()
        guard !sortedWeekdays.isEmpty else {
            if emitResponse {
                emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            }
            return false
        }

        let timeMinutes = update.timeMinutes ?? task.recurrenceTimeMinutes ?? scheduledDateClockMinutes(task.scheduledDate)
        guard let timeMinutes else {
            if emitResponse {
                emitAssistantResponse(s.chatEditNoTaskFound, nextState: .error, stream: false)
            }
            return false
        }

        task.recurrenceFrequencyRaw = RecurrenceFrequency.weekly.rawValue
        task.recurrenceWeekdaysRaw = encodeRecurrenceWeekdays(sortedWeekdays)
        task.recurrenceTimeMinutes = timeMinutes
        task.recurrenceTimeZoneIdentifier = update.timeZoneIdentifier ?? task.recurrenceTimeZoneIdentifier ?? TimeZone.current.identifier
        task.recurrenceStartDate = update.startDate ?? task.recurrenceStartDate ?? recurrenceStartDateFallback(for: task)
        task.recurrenceEndDate = update.endDate ?? task.recurrenceEndDate
        task.updatedAt = Date()

        try? persistenceContext?.save()
        TaskReminderService.shared.schedule(for: task)
        syncCalendarIfNeeded(for: task)
        if emitResponse {
            let label = TaskRecurrenceFormatting.label(for: task, locale: uiLanguage.locale) ?? "repeat schedule"
            emitAssistantResponse("Updated \(task.title): \(label).", nextState: .success, stream: true)
        }
        refreshActiveContext(from: task)
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if persistenceContext != nil {
            recordSuccessfulAIActionForAppReview()
        }
        return true
    }

    private func applyAlertStyle(task: TaskItem, style: ReminderAlertStyle, strings s: AppStrings, usageCommand: ParsedCommand?, emitResponse: Bool = true, countUsage: Bool = true) {
        Self.log.info("[VoiceChat] finalFrontendAction=updateAlertStyle finalTargetTaskID=\(task.id.uuidString, privacy: .public) title=\(task.title, privacy: .public) style=\(style.rawValue, privacy: .public)")
        print("[VoiceChat] alertStyleSelected task=\(task.id.uuidString) style=\(style.rawValue)")
        task.alertStyle = style
        task.updatedAt = Date()
        try? persistenceContext?.save()
        TaskReminderService.shared.schedule(for: task)
        print("[VoiceChat] notificationRescheduledAfterAlertStyleChange")
        if emitResponse {
            let confirmation = style == .important
                ? "Updated \(task.title): Marked as Important."
                : "Updated \(task.title): Normal reminder."
            emitAssistantResponse(
                confirmation,
                nextState: .success,
                stream: true,
                showsImportantPriorityBadge: style == .important
            )
        }
        refreshActiveContext(from: task)
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if persistenceContext != nil {
            recordSuccessfulAIActionForAppReview()
        }
    }

    private func clearRecurrence(on task: TaskItem) {
        task.recurrenceFrequencyRaw = nil
        task.recurrenceWeekdaysRaw = nil
        task.recurrenceTimeMinutes = nil
        task.recurrenceTimeZoneIdentifier = nil
        task.recurrenceStartDate = nil
        task.recurrenceEndDate = nil
    }

    private func sanitizedRecurrenceWeekdays(_ weekdays: [Int]) -> [Int] {
        Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
    }

    private func encodeRecurrenceWeekdays(_ weekdays: [Int]) -> String? {
        let sanitized = sanitizedRecurrenceWeekdays(weekdays)
        guard !sanitized.isEmpty else { return nil }
        return sanitized.map(String.init).joined(separator: ",")
    }

    private func scheduledDateClockMinutes(_ date: Date?) -> Int? {
        guard let date, TaskScheduleFormatting.hasWallClockTime(date) else { return nil }
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private func recurrenceStartDateFallback(for task: TaskItem) -> Date {
        let base = task.scheduledDate ?? Date()
        return Calendar.current.startOfDay(for: base)
    }

    private func syncCalendarIfNeeded(for task: TaskItem) {
        guard let ctx = persistenceContext else { return }
        CalendarSyncService.shared.applyOutboundEligibility(for: task)
        CalendarSyncService.shared.syncOutbound(for: task, modelContext: ctx)
    }

    // MARK: - Delete confirmation (unchanged)

    func chatConfirmDelete() {
        guard let task = pendingDeleteTask else { return }
        let usageCommand = pendingDeleteUsageCommand
        pendingDeleteUsageCommand = nil
        deleteTaskImmediately(task, usageCommand: usageCommand, emitResponse: true, countUsage: true)
    }

    private func deleteTaskImmediately(_ task: TaskItem, usageCommand: ParsedCommand?, emitResponse: Bool, countUsage: Bool) {
        let title = task.title
        let deletedId = task.id
        pendingDeleteTask = nil
        Self.log.info("[VoiceChat] deleteConfirmed title=\(title, privacy: .public)")
        if let ctx = persistenceContext {
            TaskReminderService.shared.cancel(taskID: task.id)
            CalendarSyncService.shared.removeCalendarEvent(for: task, modelContext: ctx, logDeletion: true)
            ctx.delete(task)
            try? ctx.save()
            recordSuccessfulAIActionForAppReview()
        }
        if lastActiveChatTaskContext?.taskID == deletedId {
            lastActiveChatTaskContext = nil
        }
        if countUsage {
            recordFreeAIUsageIfNeeded(usageCommand)
        }
        if emitResponse {
            emitAssistantResponse(String(format: uiLanguage.strings.chatDeleteSuccess, title), nextState: .success, stream: true)
        }
    }

    func chatCancelDelete() {
        pendingDeleteTask = nil
        pendingDeleteUsageCommand = nil
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

    // MARK: - Task resolution

    private enum TaskResolution {
        case resolved(TaskItem, confidence: EditTargetConfidence, reason: String)
        case needsConfirmation(TaskItem, reason: String)
        case needsDisambiguation([TaskItem], reason: String)
        case noMatch(String)
    }

    private func resolveEditTarget(for command: ParsedCommand) async -> TaskResolution {
        let implicitActive = isImplicitActiveTaskReference(command.originalText)
        let explicitDifferent = isExplicitDifferentTarget(command)
        logActiveTaskContext(command: command, implicitActive: implicitActive, explicitDifferent: explicitDifferent)

        if command.targetReferenceType == .taskID, let id = command.targetTaskID {
            if let task = fetchIncompleteTask(id: id) {
                Self.log.info("[VoiceChat] editTargetResolution source=backendTaskID target.reference_type=task_id finalTargetTaskID=\(task.id.uuidString, privacy: .public) skipGlobalMatching=true")
                return .resolved(task, confidence: .high, reason: "backendTaskID")
            }
            Self.log.info("[VoiceChat] editTargetResolution source=backendTaskID result=notFound target.task_id=\(id.uuidString, privacy: .public) fallback=activeContext")
        }

        if command.targetReferenceType == .recentTask, let active = lastActiveChatTaskContext {
            if let task = fetchIncompleteTask(id: active.taskID) {
                Self.log.info("[VoiceChat] editTargetResolution source=backendRecentTask target.reference_type=recent_task finalTargetTaskID=\(task.id.uuidString, privacy: .public) skipGlobalMatching=true")
                return .resolved(task, confidence: .high, reason: "backendRecentTask")
            }
            Self.log.info("[VoiceChat] editTargetResolution source=backendRecentTask result=activeTaskMissing taskID=\(active.taskID.uuidString, privacy: .public)")
        }

        if !explicitDifferent, let active = lastActiveChatTaskContext {
            if let task = fetchIncompleteTask(id: active.taskID) {
                let noOtherTarget = !hasExplicitTaskReference(command)
                if implicitActive || noOtherTarget {
                    let reason = implicitActive ? "implicitCurrentTaskReference" : "activeContextNoOtherTarget"
                    Self.log.info("[VoiceChat] editTargetResolution source=activeTaskContext actionType=\(String(describing: command.actionType), privacy: .public) reason=\(reason, privacy: .public) skipDisambiguation=true taskID=\(active.taskID.uuidString, privacy: .public) title=\(active.title, privacy: .public) scheduledDate=\(String(describing: active.scheduledDate), privacy: .public)")
                    return .resolved(task, confidence: .high, reason: reason)
                }
            }
            Self.log.info("[VoiceChat] editTargetResolution source=activeTaskContext reason=activeTaskMissing fallback=globalMatching taskID=\(active.taskID.uuidString, privacy: .public) title=\(active.title, privacy: .public)")
        }

        if explicitDifferent {
            Self.log.info("[VoiceChat] editTargetResolution source=explicitMatch actionType=\(String(describing: command.actionType), privacy: .public) reason=explicitDifferentTarget")
        } else {
            Self.log.info("[VoiceChat] editTargetResolution source=globalFallback actionType=\(String(describing: command.actionType), privacy: .public) reason=noActiveContextOrTargetMissing")
        }

        return await resolveEditTargetWithLLM(command)
    }

    private func resolveEditTargetWithLLM(_ command: ParsedCommand) async -> TaskResolution {
        let candidateTasks = taskTargetCandidates(for: command)
        guard !candidateTasks.isEmpty else {
            Self.log.info("[VoiceChat] taskResolveNoMatch reason=noCandidates")
            return .noMatch("noCandidates")
        }

        let targetTime = command.targetDate.map { ISO8601DateFormatter().string(from: $0) }
        let request = TaskTargetResolveRequest(
            userText: command.originalText,
            actionType: command.actionType.rawValue,
            targetTitle: llmTargetTitle(from: command),
            targetTime: targetTime,
            candidates: candidateTasks.map(resolveCandidatePayload),
            activeTaskID: lastActiveChatTaskContext?.taskID.uuidString,
            timezone: TimeZone.current.identifier,
            locale: uiLanguage.uiLocaleIdentifier
        )

        do {
            let response = try await taskTargetResolver.resolve(request)
            return mapLLMResolution(response, candidateTasks: candidateTasks)
        } catch {
            Self.log.error("[VoiceChat] fallbackToManualDisambiguation error=\(String(describing: error), privacy: .public)")
            let fallback = Array(candidateTasks.prefix(TaskResolverConfig.disambiguationLimit))
            return fallback.isEmpty ? .noMatch("resolverFailedNoCandidates") : .needsDisambiguation(fallback, reason: "resolverFailed")
        }
    }

    private func mapLLMResolution(_ response: TaskTargetResolveResponse, candidateTasks: [TaskItem]) -> TaskResolution {
        let byID = Dictionary(uniqueKeysWithValues: candidateTasks.map { ($0.id.uuidString, $0) })
        switch response.resolution {
        case .resolved:
            guard let id = response.selectedID, let task = byID[id] else {
                return .noMatch("resolverSelectedUnknownID")
            }
            if response.confidence >= TaskResolverConfig.highConfidence {
                return .resolved(task, confidence: .high, reason: response.reason ?? "llmResolved")
            }
            return .needsConfirmation(task, reason: response.reason ?? "llmResolvedBelowHighConfidence")
        case .needsConfirmation:
            guard let id = response.selectedID, let task = byID[id] else {
                return .noMatch("resolverConfirmationUnknownID")
            }
            return .needsConfirmation(task, reason: response.reason ?? "llmNeedsConfirmation")
        case .ambiguous:
            let tasks = (response.candidates ?? [])
                .compactMap { byID[$0] }
                .prefix(TaskResolverConfig.disambiguationLimit)
            let choices = Array(tasks)
            return choices.isEmpty ? .noMatch("resolverAmbiguousWithoutCandidates") : .needsDisambiguation(choices, reason: response.reason ?? "llmAmbiguous")
        case .noMatch:
            return .noMatch(response.reason ?? "llmNoMatch")
        }
    }

    private func taskTargetCandidates(for command: ParsedCommand) -> [TaskItem] {
        let all = fetchIncompleteTasks()
        guard !all.isEmpty else { return [] }
        let now = Date()
        let activeID = lastActiveChatTaskContext?.taskID
        let recurrenceMentioned = mentionsRecurrence(command.originalText)
        return all.sorted { lhs, rhs in
            candidatePriority(lhs, command: command, now: now, activeID: activeID, recurrenceMentioned: recurrenceMentioned)
                > candidatePriority(rhs, command: command, now: now, activeID: activeID, recurrenceMentioned: recurrenceMentioned)
        }
        .prefix(TaskResolverConfig.candidateLimit)
        .map { $0 }
    }

    private func candidatePriority(_ task: TaskItem, command: ParsedCommand, now: Date, activeID: UUID?, recurrenceMentioned: Bool) -> Int {
        var score = 0
        if task.id == activeID { score += 100 }
        if let targetDate = command.targetDate, isTask(task, near: targetDate) { score += 70 }
        if let scheduled = task.scheduledDate, scheduled >= now { score += 30 }
        if task.isRecurring, recurrenceMentioned { score += 25 }
        if now.timeIntervalSince(task.updatedAt) < 30 * 60 { score += 20 }
        if now.timeIntervalSince(task.createdAt) < 30 * 60 { score += 10 }
        return score
    }

    private func isTask(_ task: TaskItem, near targetDate: Date) -> Bool {
        if let scheduled = task.scheduledDate,
           TaskScheduleFormatting.hasWallClockTime(scheduled),
           abs(scheduled.timeIntervalSince(targetDate)) <= TaskResolverConfig.nearbyTimeWindow {
            return true
        }
        return task.recurrenceTimeMinutes == scheduledDateClockMinutes(targetDate)
    }

    private func resolveCandidatePayload(for task: TaskItem) -> TaskTargetResolveCandidate {
        TaskTargetResolveCandidate(
            id: task.id.uuidString,
            title: task.title,
            scheduledAt: task.scheduledDate.map { ISO8601DateFormatter().string(from: $0) },
            isRecurring: task.isRecurring,
            recurrenceLabel: TaskRecurrenceFormatting.label(for: task, locale: uiLanguage.locale)
        )
    }

    private func hasExplicitTaskReference(_ command: ParsedCommand) -> Bool {
        command.targetDate != nil || llmTargetTitle(from: command) != nil
    }

    private func llmTargetTitle(from command: ParsedCommand) -> String? {
        let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let lower = title.lowercased()
        let generic = ["move meeting", "move task", "reschedule", "delete task", "rename task", "append", "update recurrence"]
        return generic.contains(lower) ? nil : title
    }

    private func mentionsRecurrence(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("repeat")
            || lower.contains("recurr")
            || lower.contains("every")
            || lower.contains("每周")
            || lower.contains("周一")
            || lower.contains("周二")
            || lower.contains("周三")
            || lower.contains("周四")
            || lower.contains("周五")
            || lower.contains("周六")
            || lower.contains("周日")
            || lower.contains("星期")
    }

    private func fetchIncompleteTasks() -> [TaskItem] {
        guard let ctx = persistenceContext else { return [] }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isCompleted }
        )
        return (try? ctx.fetch(descriptor)) ?? []
    }

    private func commandCandidateTasks() -> [TaskItem] {
        let now = Date()
        return fetchIncompleteTasks()
            .sorted {
                commandCandidatePriority($0, now: now) > commandCandidatePriority($1, now: now)
            }
            .prefix(TaskResolverConfig.candidateLimit)
            .map { $0 }
    }

    private func commandCandidatePriority(_ task: TaskItem, now: Date) -> Int {
        var score = 0
        if task.id == lastActiveChatTaskContext?.taskID { score += 100 }
        if let scheduled = task.scheduledDate, scheduled >= now { score += 30 }
        if task.isRecurring { score += 20 }
        if now.timeIntervalSince(task.updatedAt) < 30 * 60 { score += 20 }
        if now.timeIntervalSince(task.createdAt) < 30 * 60 { score += 10 }
        return score
    }

    private func commandTaskSnapshot(for task: TaskItem) -> CommandInterpretTaskSnapshot {
        CommandInterpretTaskSnapshot(
            id: task.id.uuidString,
            title: task.title,
            scheduledAt: task.scheduledDate.map { ISO8601DateFormatter().string(from: $0) },
            isRecurring: task.isRecurring,
            recurrenceLabel: TaskRecurrenceFormatting.label(for: task, locale: uiLanguage.locale),
            notesSnippet: task.notes.map { String($0.prefix(240)) }
        )
    }

    private func activeInterpretTaskSnapshot() -> CommandInterpretTaskSnapshot? {
        guard let active = lastActiveChatTaskContext,
              let task = fetchIncompleteTask(id: active.taskID) else { return nil }
        return commandTaskSnapshot(for: task)
    }

    private func taskForInterpretedTarget(_ result: CommandInterpretResponse) -> TaskItem? {
        guard let id = result.target?.selectedTaskID.flatMap(UUID.init(uuidString:)) else { return nil }
        return fetchIncompleteTask(id: id)
    }

    private func tasksForInterpretedCandidateIDs(_ ids: [String]) -> [TaskItem] {
        ids.compactMap { UUID(uuidString: $0) }.compactMap(fetchIncompleteTask)
    }

    private func parseInterpretedDate(_ raw: String) -> Date? {
        let tz = TimeZone.current
        let f1 = ISO8601DateFormatter()
        f1.timeZone = tz
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f1.date(from: raw) { return date }
        let f2 = ISO8601DateFormatter()
        f2.timeZone = tz
        f2.formatOptions = [.withInternetDateTime]
        if let date = f2.date(from: raw) { return date }
        return nil
    }

    private func alertStyle(from raw: String?) -> ReminderAlertStyle? {
        ReminderAlertStyle.parsed(fromRaw: raw)
    }

    private func parsedCommand(from result: CommandInterpretResponse) -> ParsedCommand? {
        guard let create = result.create,
              let title = create.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let scheduled = create.scheduledAt.flatMap(parseInterpretedDate)
        let end = create.endAt.flatMap(parseInterpretedDate)
        let recurrence = parsedRecurrence(from: create, scheduledDate: scheduled)
        let action: ActionType = result.actionType == "createEvent" ? .calendarEvent : .reminder
        return ParsedCommand(
            originalText: "",
            actionType: action,
            title: title,
            notes: create.notes,
            startDate: action == .calendarEvent ? scheduled : nil,
            endDate: end,
            reminderDate: action == .reminder ? scheduled : nil,
            confidence: result.confidence,
            parserSource: .llm,
            languageCode: uiLanguage.uiLocaleIdentifier,
            recurrence: recurrence,
            alertStyle: alertStyle(from: create.alertStyle)
        )
    }

    private func parsedRecurrence(from create: CommandInterpretResponse.Create, scheduledDate: Date?) -> ParsedRecurrence? {
        guard create.recurrenceType == "weekly" else { return nil }
        let weekdays = sanitizedRecurrenceWeekdays(create.recurrenceWeekdays ?? [])
        guard !weekdays.isEmpty else { return nil }
        return ParsedRecurrence(
            frequency: .weekly,
            weekdays: weekdays,
            timeMinutes: scheduledDateClockMinutes(scheduledDate),
            timeZoneIdentifier: TimeZone.current.identifier,
            startDate: scheduledDate.map { Calendar.current.startOfDay(for: $0) },
            endDate: create.recurrenceEndAt.flatMap(parseInterpretedDate)
        )
    }

    private func recurrenceUpdate(from result: CommandInterpretResponse) -> ParsedRecurrenceUpdate? {
        guard let edit = result.edit else { return nil }
        if edit.newRecurrenceType == "weekly", let weekdays = edit.newRecurrenceWeekdays {
            return ParsedRecurrenceUpdate(
                operation: .setWeekdays,
                weekdays: sanitizedRecurrenceWeekdays(weekdays),
                timeMinutes: nil,
                timeZoneIdentifier: TimeZone.current.identifier,
                startDate: nil,
                endDate: nil
            )
        }
        if edit.newRecurrenceType == "none" {
            return ParsedRecurrenceUpdate(operation: .clearRecurrence)
        }
        if let raw = edit.newScheduledAt, let date = parseInterpretedDate(raw) {
            return ParsedRecurrenceUpdate(
                operation: .setTime,
                weekdays: nil,
                timeMinutes: scheduledDateClockMinutes(date),
                timeZoneIdentifier: TimeZone.current.identifier,
                startDate: nil,
                endDate: nil
            )
        }
        return nil
    }

    private func isImplicitActiveTaskReference(_ text: String) -> Bool {
        let lower = text.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")
        let phrases = [
            "this", "it", "this task", "current task", "the current task",
            "这个", "這個", "这个任务", "這個任務", "这个提醒", "這個提醒",
            "它", "它们", "它們", "刚才那个", "剛才那個", "上一个任务", "上一個任務", "上个任务", "上個任務"
        ]
        return phrases.contains { phrase in
            let normalized = phrase.lowercased().replacingOccurrences(of: " ", with: "")
            return compact.contains(normalized)
        }
    }

    private func isExplicitDifferentTarget(_ command: ParsedCommand) -> Bool {
        if isImplicitActiveTaskReference(command.originalText) {
            return false
        }
        let lower = command.originalText.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")
        if compact.contains("那个") || compact.contains("那個") {
            return true
        }
        let explicitCJKTargetMarkers = ["的提醒", "的任务", "的任務", "的会议", "的會議"]
        if command.targetDate != nil,
           explicitCJKTargetMarkers.contains(where: { compact.contains($0) }) {
            return true
        }
        let explicitEnglishPatterns = [
            #"the\s+.+\s+task"#,
            #"the\s+.+\s+reminder"#,
            #"the\s+.+\s+meeting"#,
        ]
        return explicitEnglishPatterns.contains { pattern in
            lower.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func logActiveTaskContext(command: ParsedCommand, implicitActive: Bool, explicitDifferent: Bool) {
        if let ctx = lastActiveChatTaskContext {
            Self.log.info("[VoiceChat] activeTaskContext taskID=\(ctx.taskID.uuidString, privacy: .public) title=\(ctx.title, privacy: .public) scheduledDate=\(String(describing: ctx.scheduledDate), privacy: .public) actionType=\(String(describing: command.actionType), privacy: .public) implicitReference=\(implicitActive, privacy: .public) explicitDifferentTarget=\(explicitDifferent, privacy: .public)")
        } else {
            Self.log.info("[VoiceChat] activeTaskContext nil actionType=\(String(describing: command.actionType), privacy: .public) implicitReference=\(implicitActive, privacy: .public) explicitDifferentTarget=\(explicitDifferent, privacy: .public)")
        }
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
        let reply = confirmationMessage(for: command, userTranscript: command.originalText)
        commitCreateWithConflictCheck(command, reply: reply)
    }

    private func commitCreateWithConflictCheck(_ command: ParsedCommand, reply: String? = nil, emitResponse: Bool = true, countUsage: Bool = true) {
        let reply = reply ?? (command.actionType == .calendarEvent ? "Added \(command.title)." : confirmationMessage(for: command, userTranscript: command.originalText))
        var didPersistNewTask = false
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
            didPersistNewTask = true
            Self.log.info("""
                [VoiceChat] finalFrontendAction=createTask \
                activeContextUsed=false \
                title=\(command.title, privacy: .public) \
                scheduledDate=\(String(describing: resolvedDate), privacy: .public) \
                actionType=\(String(describing: command.actionType), privacy: .public)
                """)
        }
        if emitResponse {
            emitAssistantResponse(reply, nextState: .success, stream: true)
        }
        if countUsage {
            recordFreeAIUsageIfNeeded(command)
        }
        if didPersistNewTask {
            recordSuccessfulAIActionForAppReview()
        }
    }

    func clearActiveChatTaskContext() {
        if let ctx = lastActiveChatTaskContext {
            Self.log.info("[VoiceChat] activeTaskContextCleared taskID=\(ctx.taskID.uuidString, privacy: .public) title=\(ctx.title, privacy: .public)")
        }
        lastActiveChatTaskContext = nil
    }

    private func refreshActiveContext(from task: TaskItem) {
        lastActiveChatTaskContext = ChatActiveTaskContext(
            taskID: task.id,
            title: task.title,
            scheduledDate: task.scheduledDate,
            notes: task.notes,
            recurrenceFrequency: task.recurrenceFrequency,
            recurrenceWeekdays: task.recurrenceWeekdays,
            recurrenceTimeMinutes: task.recurrenceTimeMinutes,
            recurrenceTimeZoneIdentifier: task.recurrenceTimeZoneIdentifier
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
        isChatSheetPresented = false
        cancelAutoRelisten(reason: "sheetDismissed")
        cancelFollowUpNoSpeechTimer(reason: "sheetDismissed")
        speechService.onPartialTranscript = nil
        speechService.onSpeechDetected = nil
        await speechService.cancelForReset()
        cancelMaxRecordingTimer()
        cancelAllProcessingStatusHints()
        cancelStreamReveal()
        pendingAssistantSlotId = nil
        voiceDraftErrorMessage = nil
        showExtendedThinkingStatus = false
        chatFlowState = .idle
        chatDraftText = ""
        isTextEditing = false
        voiceDraftAwaitingSubmit = false
        currentSubmitCameFromVoiceDraft = false
        currentListeningIsAutoFollowUp = false
        voiceFollowUpAutoStartsRemaining = 0
        pendingVoiceTranscript = ""
        chatMessages = []
        parsedCommand = nil
        pendingConflictCommand = nil
        pendingDeleteTask = nil
        pendingDeleteUsageCommand = nil
        confirmationCandidate = nil
        pendingConfirmationUsageCommand = nil
        pendingEditAction = nil
        pendingDisambiguationUsageCommand = nil
        pendingConfirmationPayload = nil
        confirmationCandidate = nil
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

    func chatCandidateMetadata(for task: TaskItem) -> String? {
        var parts: [String] = []
        if let d = task.scheduledDate, TaskScheduleFormatting.hasWallClockTime(d) {
            parts.append(shortTimeFormatter.string(from: d))
        }
        if let recurrence = TaskRecurrenceFormatting.label(for: task, locale: uiLanguage.locale) {
            parts.append(recurrence)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func editConfirmationMessage(for task: TaskItem) -> String {
        let metadata = chatCandidateMetadata(for: task)
        if uiLanguage == .en {
            if let metadata {
                return "Did you mean “\(task.title)” (\(metadata))?"
            }
            return "Did you mean “\(task.title)”?"
        }
        if let metadata {
            return "你是指「\(task.title)」\(metadata) 吗？"
        }
        return "你是指「\(task.title)」吗？"
    }

    private func editDisambiguationMessage() -> String {
        uiLanguage == .en ? "Which task do you want to edit?" : "你想修改哪一个任务？"
    }

    private func noTaskMatchMessage(strings s: AppStrings) -> String {
        uiLanguage == .en
            ? "I couldn’t find that task. Try saying the title or time again."
            : "我找不到那个任务。请再说一次标题或时间。"
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
