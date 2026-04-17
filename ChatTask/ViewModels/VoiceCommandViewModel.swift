import Foundation
import os.log
import SwiftData

// MARK: - Chat types (unchanged)

enum ChatMessageRole: String, Equatable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatMessageRole
    let text: String
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
    var chatFlowState: VoiceFlowState = .idle
    var chatDraftText: String = ""
    /// Set after voice capture completes. The view observes this and moves it into the text
    /// field so the user can review and edit before sending. Cleared by the view after pickup.
    var pendingVoiceTranscript: String = ""
    var parsedCommand: ParsedCommand?
    var disambiguationCandidates: [TaskItem] = []

    private var pendingConflictCommand: ParsedCommand?
    private var pendingDeleteTask: TaskItem?
    private var pendingEditAction: PendingEditAction?

    // MARK: - Pending edit model (unchanged)

    private enum PendingEditType {
        case delete
        case reschedule(newDate: Date)
        case appendNote(text: String)
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
        case .processing: return s.voiceProcessing
        case .conflictPending, .deletePending, .disambiguating: return ""
        case .success:    return s.voiceReady
        case .error:      return s.voiceError
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
        chatFlowState = .processing
        // Typed text is already final — go straight to parse, using the local-first strategy.
        parsingCoordinator.strategy = .localFirst
        chatMessages.append(ChatMessage(role: .user, text: trimmed))
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
            Self.log.info("[VoiceChat] stopReason=manual — user tapped mic to stop")
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

    // MARK: - Begin listening

    func chatBeginListening() async {
        cancelMaxRecordingTimer()

        let msgs = uiLanguage.speechMessages
        Self.log.info("[VoiceChat] localListeningStart appUILanguage=\(self.uiLanguage.rawValue, privacy: .public)")

        // Attach partial-transcript callback (set here so the callback captures the current ViewModel).
        speechService.onPartialTranscript = { [weak self] text in
            guard let self, self.chatFlowState == .listening else { return }
            self.chatDraftText = text
        }

        // Request both microphone + speech recognition permissions.
        // Speech recognition denial degrades to audio-only — not a fatal error.
        if let err = await speechService.requestAuthorizationIfNeeded(messages: msgs) {
            chatMessages.append(ChatMessage(role: .assistant, text: err))
            chatFlowState = .error
            return
        }

        chatDraftText = ""

        let startError = await speechService.startListening(
            locale: uiLanguage.locale,
            messages: msgs,
            onAutoStop: { [weak self] in
                guard let self, self.chatFlowState == .listening else { return }
                Self.log.info("[VoiceChat] stopReason=autoSilence — silence threshold reached")
                Task { await self.chatFinalizeListening() }
            }
        )

        if let startError {
            chatMessages.append(ChatMessage(role: .assistant, text: startError))
            chatFlowState = .error
            return
        }

        chatFlowState = .listening
        startMaxRecordingTimer()
        Self.log.info("[VoiceChat] listening active — local recognition + audio recording running; max timeout=30s")
    }

    // MARK: - Finalize listening (orchestrator)

    func chatFinalizeListening() async {
        guard chatFlowState == .listening else { return }
        cancelMaxRecordingTimer()
        chatFlowState = .processing
        chatDraftText = ""

        Self.log.info("[VoiceChat] stoppingListening")
        let captureOutcome = await speechService.stopListening()
        let strings = uiLanguage.strings
        let speechMsgs = uiLanguage.speechMessages

        switch captureOutcome {
        case .failure(let error):
            handleCaptureFailure(error, strings: strings, speechMsgs: speechMsgs)

        case .success(let captureResult):
            Self.log.info("[VoiceChat] captureSuccess localTranscript=\(captureResult.transcript, privacy: .public) confidence=\(String(describing: captureResult.confidence), privacy: .public) duration=\(captureResult.duration, privacy: .public)s audioURL=\(captureResult.audioURL?.path ?? "nil", privacy: .public)")
            await handleLocalSpeechResult(captureResult, strings: strings)
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
        chatMessages.append(ChatMessage(role: .assistant, text: userMsg))
        parsedCommand = nil
        chatFlowState = .error
    }

    // MARK: - Local speech result handler

    private func handleLocalSpeechResult(
        _ captureResult: LocalSpeechCaptureResult,
        strings: AppStrings
    ) async {
        // Quick local eval to inform the routing decision (no network).
        let localParsed = await localEvaluator.evaluate(
            transcript: captureResult.transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )

        let routingDecision = transcriptionRouter.evaluate(
            transcript: captureResult.transcript,
            confidence: captureResult.confidence,
            duration: captureResult.duration,
            parsedCommand: localParsed
        )

        switch routingDecision {
        case .acceptLocalTranscript(let trimmed):
            Self.log.info("[VoiceChat] routingDecision=acceptLocal transcript=\(trimmed, privacy: .public)")
            defer { deleteAudioFile(captureResult.audioURL) }
            deliverTranscriptToInputField(trimmed)

        case .fallbackToCloud:
            guard let audioURL = captureResult.audioURL else {
                chatMessages.append(ChatMessage(role: .assistant, text: strings.chatErrorNothingRecorded))
                chatFlowState = .error
                return
            }
            Self.log.info("[VoiceChat] routingDecision=fallbackToCloud — uploading audio")
            await handleCloudFallback(audioURL: audioURL, strings: strings)
        }
    }

    // MARK: - Cloud fallback handler

    private func handleCloudFallback(audioURL: URL, strings: AppStrings) async {
        defer { deleteAudioFile(audioURL) }

        let transcript: String
        do {
            Self.log.info("[VoiceChat] cloudTranscriptionStart audioURL=\(audioURL.path, privacy: .public)")
            transcript = try await transcriptionService.transcribe(audioFileURL: audioURL)
            Self.log.info("[VoiceChat] cloudTranscriptionSuccess transcript=\(transcript, privacy: .public)")
        } catch {
            // Map each error category to a precise log string (for debugging)
            // and a clean user-facing message (no API / HTTP / internal terms).
            let rootCause: String
            let userMessage: String
            switch error {
            case MultilingualTranscriptionError.fileReadFailed(let u):
                rootCause = "fileReadFailed — \(u.localizedDescription)"
                userMessage = strings.chatErrorSomethingWentWrong
            case MultilingualTranscriptionError.fileEmpty:
                rootCause = "fileEmpty — audio file was empty or contained no speech frames"
                userMessage = strings.chatErrorNothingRecorded
            case MultilingualTranscriptionError.networkError(let u):
                rootCause = "networkError — \(u.localizedDescription)"
                userMessage = strings.chatErrorOffline
            case MultilingualTranscriptionError.httpError(let code, let body):
                rootCause = "httpError — status=\(code) body=\(body.prefix(200))"
                userMessage = strings.chatErrorServiceUnavailable
            case MultilingualTranscriptionError.decodingFailed(let u, let raw):
                rootCause = "decodingFailed — \(u.localizedDescription) rawBody=\(raw.prefix(200))"
                userMessage = strings.chatErrorSomethingWentWrong
            default:
                rootCause = "unknown — \(String(describing: error))"
                userMessage = strings.chatErrorSomethingWentWrong
            }
            Self.log.error("[VoiceChat] cloudTranscriptionFailure rootCause=\(rootCause, privacy: .public)")
            chatMessages.append(ChatMessage(role: .assistant, text: userMessage))
            parsedCommand = nil
            chatFlowState = .error
            return
        }

        deliverTranscriptToInputField(transcript)
    }

    // MARK: - Transcript → input field delivery

    /// Places the transcribed text into the input field for the user to review and send.
    /// This is the final step of the voice pipeline — the user then taps send (or return)
    /// which routes through `chatSubmitTypedText`, the same path as manual typed input.
    private func deliverTranscriptToInputField(_ rawTranscript: String) {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            chatMessages.append(ChatMessage(role: .assistant, text: uiLanguage.strings.chatEmptyTranscript))
            chatFlowState = .error
            return
        }
        Self.log.info("[VoiceChat] transcriptDeliveredToInputField=\(trimmed, privacy: .public)")
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
            timeZoneIdentifier: TimeZone.current.identifier
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
            chatMessages.append(ChatMessage(role: .assistant, text: warning))
            chatFlowState = .conflictPending
            return
        }

        commitSave(command: command)
    }

    // MARK: - Edit intent handlers (unchanged)

    private func handleDeleteIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        switch resolveTargetTask(near: command.targetDate) {
        case .notFound:
            Self.log.info("[VoiceChat] deleteIntent — no task found near targetDate=\(String(describing: command.targetDate), privacy: .public)")
            chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
            chatFlowState = .error
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
        switch resolveTargetTask(near: command.targetDate) {
        case .notFound:
            Self.log.info("[VoiceChat] rescheduleIntent — no task found")
            chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
            chatFlowState = .error
        case .ambiguous(let matches):
            Self.log.info("[VoiceChat] rescheduleIntent — ambiguous matchCount=\(matches.count, privacy: .public)")
            guard let newDate = command.newScheduledDate else {
                chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
                chatFlowState = .error
                return
            }
            enterDisambiguation(matches: matches, editType: .reschedule(newDate: newDate), strings: s)
        case .found(let task):
            guard let newDate = command.newScheduledDate else {
                Self.log.warning("[VoiceChat] rescheduleIntent — newScheduledDate is nil")
                chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
                chatFlowState = .error
                return
            }
            applyReschedule(task: task, newDate: newDate, strings: s)
        }
    }

    private func handleAppendIntent(_ command: ParsedCommand) {
        let s = uiLanguage.strings
        let text = command.appendText ?? command.title
        guard !text.isEmpty else {
            chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
            chatFlowState = .error
            return
        }
        switch resolveTargetTask(near: command.targetDate) {
        case .notFound:
            Self.log.info("[VoiceChat] appendIntent — no task found")
            chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditNoTaskFound))
            chatFlowState = .error
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
            chatMessages.append(ChatMessage(role: .assistant, text: s.chatEditAmbiguousTask))
            chatFlowState = .error
            return
        }
        Self.log.info("[VoiceChat] enterDisambiguation count=\(matches.count, privacy: .public)")
        disambiguationCandidates = matches
        pendingEditAction = PendingEditAction(type: editType)
        chatMessages.append(ChatMessage(role: .assistant,
                                        text: String(format: s.chatDisambiguateSelect, matches.count)))
        chatFlowState = .disambiguating
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
        }
    }

    // MARK: - Shared edit operations (unchanged)

    private func enterDeleteConfirmation(for task: TaskItem, strings s: AppStrings) {
        pendingDeleteTask = task
        let prompt = String(format: s.chatDeletePrompt, task.title)
        chatMessages.append(ChatMessage(role: .assistant, text: prompt))
        chatFlowState = .deletePending
    }

    private func applyReschedule(task: TaskItem, newDate: Date, strings s: AppStrings) {
        Self.log.info("[VoiceChat] rescheduleApplied title=\(task.title, privacy: .public) newDate=\(newDate, privacy: .public)")
        task.scheduledDate = newDate
        task.updatedAt = Date()
        try? persistenceContext?.save()
        let timeStr = shortTimeFormatter.string(from: newDate)
        chatMessages.append(ChatMessage(role: .assistant,
                                        text: String(format: s.chatRescheduleSuccess, task.title, timeStr)))
        chatFlowState = .success
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
        chatMessages.append(ChatMessage(role: .assistant,
                                        text: String(format: s.chatAppendSuccess, task.title)))
        chatFlowState = .success
    }

    // MARK: - Delete confirmation (unchanged)

    func chatConfirmDelete() {
        guard let task = pendingDeleteTask else { return }
        let title = task.title
        pendingDeleteTask = nil
        Self.log.info("[VoiceChat] deleteConfirmed title=\(title, privacy: .public)")
        if let ctx = persistenceContext {
            TaskReminderService.shared.cancel(taskID: task.id)
            ctx.delete(task)
            try? ctx.save()
        }
        chatMessages.append(ChatMessage(role: .assistant,
                                        text: String(format: uiLanguage.strings.chatDeleteSuccess, title)))
        chatFlowState = .success
    }

    func chatCancelDelete() {
        pendingDeleteTask = nil
        chatMessages.append(ChatMessage(role: .assistant, text: uiLanguage.strings.chatDeleteCanceled))
        chatFlowState = .error
    }

    // MARK: - Conflict confirmation (unchanged)

    func chatConfirmConflict() {
        guard let command = pendingConflictCommand else { return }
        pendingConflictCommand = nil
        commitSave(command: command)
    }

    func chatCancelConflict() {
        pendingConflictCommand = nil
        chatMessages.append(ChatMessage(role: .assistant, text: uiLanguage.strings.chatConflictCanceled))
        chatFlowState = .error
    }

    // MARK: - Task resolution (unchanged)

    private enum TaskResolution {
        case found(TaskItem)
        case ambiguous([TaskItem])
        case notFound
    }

    private func resolveTargetTask(near targetDate: Date?) -> TaskResolution {
        guard let targetDate, let ctx = persistenceContext else { return .notFound }
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
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    // MARK: - Helpers (unchanged)

    private func commitSave(command: ParsedCommand) {
        let reply = confirmationMessage(for: command, userTranscript: command.originalText)
        chatMessages.append(ChatMessage(role: .assistant, text: reply))
        if let ctx = persistenceContext {
            let resolvedDate = command.reminderDate ?? command.startDate
            print("""
            [VoiceChat] commitSave
              title='\(command.title)'
              scheduledDate=\(String(describing: resolvedDate))
              reminderOffsetMinutes=\(ReminderOffset.globalDefault.rawValue) (globalDefault)
            """)
            TaskItem.insertFromParsedCommand(command, context: ctx)
            Self.log.info("""
                [VoiceChat] taskSaveSuccess \
                title=\(command.title, privacy: .public) \
                scheduledDate=\(String(describing: resolvedDate), privacy: .public) \
                actionType=\(String(describing: command.actionType), privacy: .public)
                """)
        }
        chatFlowState = .success
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
        chatFlowState = .idle
        chatDraftText = ""
        pendingVoiceTranscript = ""
        chatMessages = []
        parsedCommand = nil
        pendingConflictCommand = nil
        pendingDeleteTask = nil
        pendingEditAction = nil
        disambiguationCandidates = []
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
