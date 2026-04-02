import Foundation
import os.log
import SwiftData

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

@MainActor
@Observable
final class VoiceCommandViewModel {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "VoiceChat")

    var chatMessages: [ChatMessage] = []
    var chatFlowState: VoiceFlowState = .idle
    var chatDraftText: String = ""
    var parsedCommand: ParsedCommand?
    /// Candidate tasks exposed to the view during disambiguation.
    var disambiguationCandidates: [TaskItem] = []

    /// Holds a parsed command that is waiting for the user to confirm or dismiss a conflict warning.
    private var pendingConflictCommand: ParsedCommand?
    /// Holds a task that is waiting for delete confirmation.
    private var pendingDeleteTask: TaskItem?
    /// Holds the pending edit action while the user is choosing among disambiguation candidates.
    private var pendingEditAction: PendingEditAction?

    // MARK: - Pending edit model

    private enum PendingEditType {
        case delete
        case reschedule(newDate: Date)
        case appendNote(text: String)
    }

    private struct PendingEditAction {
        let type: PendingEditType
    }

    /// In-app UI language only (labels, helper text, date formatting). Does not select speech recognition locale.
    var uiLanguage: AppUILanguage = .defaultForDevice()

    private let speechService = SpeechRecognizerService()
    private let transcriptionService = MultilingualTranscriptionService()
    private let parsingCoordinator = TaskParsingCoordinator(
        localParser: LocalTaskParser(),
        llmParser: LLMTaskParserService()
    )
    private var persistenceContext: ModelContext?
    private var silenceTimerTask: Task<Void, Never>?

    func attachPersistence(_ context: ModelContext) {
        persistenceContext = context
    }

    var chatStatusDescription: String {
        let s = uiLanguage.strings
        switch chatFlowState {
        case .idle: return s.voiceTapToSpeak
        case .listening: return s.voiceListening
        case .processing: return s.voiceProcessing
        case .conflictPending, .deletePending, .disambiguating: return ""
        case .success: return s.voiceReady
        case .error: return s.voiceError
        }
    }

    /// Call when UI language changes while this view model may be active (e.g. chat sheet open).
    func handleUILanguageChanged() async {
        await speechService.cancelForReset()
        cancelMaxRecordingTimer()
        if chatFlowState == .listening {
            chatFlowState = .idle
            chatDraftText = ""
        }
    }

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

    /// 30-second safety net — fires only if silence-based auto-stop and manual stop both fail.
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

    func chatBeginListening() async {
        cancelMaxRecordingTimer()

        let msgs = uiLanguage.speechMessages
        Self.log.info("[VoiceChat] recording start appUILanguage=\(self.uiLanguage.rawValue, privacy: .public)")

        if let err = await speechService.requestAuthorizationIfNeeded(messages: msgs) {
            chatMessages.append(ChatMessage(role: .assistant, text: err))
            chatFlowState = .error
            return
        }

        chatDraftText = ""

        let startError = await speechService.startRecording(messages: msgs, onAutoStop: { [weak self] in
            guard let self, self.chatFlowState == .listening else { return }
            Self.log.info("[VoiceChat] stopReason=autoSilence — silence threshold reached, stopping recording")
            Task { await self.chatFinalizeListening() }
        })

        if let startError {
            chatMessages.append(ChatMessage(role: .assistant, text: startError))
            chatFlowState = .error
            return
        }

        chatFlowState = .listening
        startMaxRecordingTimer()
        Self.log.info("[VoiceChat] recording active — silence detection running; max timeout=30s")
    }

    func chatFinalizeListening() async {
        // Guard against double-invocation (auto-stop and manual tap arriving close together).
        guard chatFlowState == .listening else { return }
        cancelMaxRecordingTimer()
        chatFlowState = .processing
        Self.log.info("[VoiceChat] stopping recording")
        let recordOutcome = await speechService.stopRecording()
        let strings = uiLanguage.strings
        let speechMsgs = uiLanguage.speechMessages

        switch recordOutcome {
        case .failure(let error):
            chatDraftText = ""
            let ns = error as NSError
            // "Too small" means the recorder captured no real audio — show "no speech" hint rather than a generic error.
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
        case .success(let audioURL):
            Self.log.info("[VoiceChat] audio file ready path=\(audioURL.path, privacy: .public)")
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let transcript: String
            do {
                transcript = try await transcriptionService.transcribe(audioFileURL: audioURL)
            } catch {
                chatDraftText = ""
                let rootCause: String
                switch error {
                case MultilingualTranscriptionError.missingAPIKey:
                    rootCause = "missingAPIKey"
                case MultilingualTranscriptionError.fileReadFailed(let u):
                    rootCause = "fileReadFailed — \(u.localizedDescription)"
                case MultilingualTranscriptionError.fileEmpty:
                    rootCause = "fileEmpty — AVAudioRecorder produced empty/near-empty container (likely recorded silence or was stopped immediately)"
                case MultilingualTranscriptionError.networkError(let u):
                    rootCause = "networkError — \(u.localizedDescription)"
                case MultilingualTranscriptionError.httpError(let code, _):
                    rootCause = "http\(code)"
                case MultilingualTranscriptionError.decodingFailed(let u, _):
                    rootCause = "decodingFailed — \(u.localizedDescription)"
                default:
                    rootCause = "unknown — \(String(describing: error))"
                }
                Self.log.error("[VoiceChat] transcriptionFailureRootCause=\(rootCause, privacy: .public)")
                chatMessages.append(ChatMessage(role: .assistant, text: strings.chatTranscriptionFailed))
                parsedCommand = nil
                chatFlowState = .error
                return
            }

            chatDraftText = ""
            Self.log.info("[VoiceChat] transcript (API)=\(transcript, privacy: .public)")
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                chatMessages.append(
                    ChatMessage(role: .assistant, text: strings.chatEmptyTranscript)
                )
                chatFlowState = .error
            } else {
                chatMessages.append(ChatMessage(role: .user, text: trimmed))
                await applyChatParse(transcript: trimmed)
            }
        }
    }

    private func localizedStopFailure(_ error: Error, speechMsgs: SpeechServiceMessages) -> String {
        let ns = error as NSError
        if ns.domain == VocaTimeSpeechDomain.name, let code = VocaTimeSpeechErrorCode(rawValue: ns.code) {
            switch code {
            case .nothingToStop: return speechMsgs.nothingToStop
            case .interrupted: return speechMsgs.interrupted
            case .recordingFailed: return speechMsgs.recognitionStopped
            case .generic: break
            }
        }
        return ns.localizedDescription
    }

    /// Resets all session state so the next sheet presentation starts clean.
    /// Called from `ChatSheetView.onDisappear` — safe to call on any dismiss (success, manual, or error).
    func prepareForNewSession() async {
        await speechService.cancelForReset()
        cancelMaxRecordingTimer()
        chatFlowState = .idle
        chatDraftText = ""
        chatMessages = []
        parsedCommand = nil
        pendingConflictCommand = nil
        pendingDeleteTask = nil
        pendingEditAction = nil
        disambiguationCandidates = []
        Self.log.info("[VoiceChat] chatDismissReset completed — state ready for new session")
    }

    private func applyChatParse(transcript: String) async {
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
        if let date = scheduledDate,
           TaskScheduleFormatting.hasWallClockTime(date),
           let conflicting = findConflictingTask(near: date) {
            Self.log.info("[VoiceChat] conflictDetected existingTitle=\(conflicting.title, privacy: .public) newTitle=\(command.title, privacy: .public)")
            pendingConflictCommand = command
            let timeStr = shortTimeFormatter.string(from: date)
            let warning = String(format: uiLanguage.strings.chatConflictWarning,
                                 conflicting.title, timeStr, command.title)
            chatMessages.append(ChatMessage(role: .assistant, text: warning))
            chatFlowState = .conflictPending
            return
        }

        commitSave(command: command)
    }

    // MARK: - Edit intent handlers

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

    // MARK: - Disambiguation

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

    /// Called when the user taps a candidate task during disambiguation.
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

    // MARK: - Shared edit operations

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

    // MARK: - Delete confirmation

    /// User tapped "Delete" — remove the pending task.
    func chatConfirmDelete() {
        guard let task = pendingDeleteTask else { return }
        let title = task.title
        pendingDeleteTask = nil
        Self.log.info("[VoiceChat] deleteConfirmed title=\(title, privacy: .public)")
        if let ctx = persistenceContext {
            ctx.delete(task)
            try? ctx.save()
        }
        chatMessages.append(ChatMessage(role: .assistant,
                                        text: String(format: uiLanguage.strings.chatDeleteSuccess, title)))
        chatFlowState = .success
    }

    /// User tapped "Keep it" — cancel the pending delete.
    func chatCancelDelete() {
        pendingDeleteTask = nil
        chatMessages.append(ChatMessage(role: .assistant, text: uiLanguage.strings.chatDeleteCanceled))
        chatFlowState = .error
    }

    // MARK: - Conflict confirmation

    /// User chose "Add anyway" — save the pending command and finish.
    func chatConfirmConflict() {
        guard let command = pendingConflictCommand else { return }
        pendingConflictCommand = nil
        commitSave(command: command)
    }

    /// User chose "Don't add" — discard the pending command.
    func chatCancelConflict() {
        pendingConflictCommand = nil
        chatMessages.append(ChatMessage(role: .assistant, text: uiLanguage.strings.chatConflictCanceled))
        chatFlowState = .error
    }

    // MARK: - Task resolution

    private enum TaskResolution {
        case found(TaskItem)
        case ambiguous([TaskItem])
        case notFound
    }

    /// Finds non-completed, timed tasks within ±15 minutes of `targetDate`.
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

    // MARK: - Helpers

    /// Inserts the task into SwiftData and transitions to `.success`.
    private func commitSave(command: ParsedCommand) {
        let reply = confirmationMessage(for: command, userTranscript: command.originalText)
        chatMessages.append(ChatMessage(role: .assistant, text: reply))
        if let ctx = persistenceContext {
            TaskItem.insertFromParsedCommand(command, context: ctx)
            Self.log.info("[VoiceChat] taskSaveSuccess title=\(command.title, privacy: .public) actionType=\(String(describing: command.actionType), privacy: .public)")
        }
        chatFlowState = .success
    }

    /// Returns the first non-completed task with a wall-clock time within ±15 minutes of `date`.
    private func findConflictingTask(near date: Date) -> TaskItem? {
        guard let ctx = persistenceContext else { return nil }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isCompleted }
        )
        let candidates = (try? ctx.fetch(descriptor)) ?? []
        let window: TimeInterval = 15 * 60
        return candidates.first { item in
            guard let d = item.scheduledDate,
                  TaskScheduleFormatting.hasWallClockTime(d) else { return false }
            return abs(d.timeIntervalSince(date)) <= window
        }
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
                label = "“\(name)”"
            } else {
                label = "「\(name)」"
            }
            return String(format: s.chatUnknownSchedule, label)
        }

        let low = userTranscript.lowercased()
        if command.actionType == .reminder {
            if let n = extractLeadingMinutes(from: low) {
                return n == 1
                    ? String(format: s.chatReminderMinutes, n)
                    : String(format: s.chatReminderMinutesPlural, n)
            }
            if let n = extractLeadingHours(from: low) {
                return n == 1
                    ? String(format: s.chatReminderHours, n)
                    : String(format: s.chatReminderHoursPlural, n)
            }
            if let when = command.reminderDate {
                let t = replyDateFormatter.string(from: when)
                return String(format: s.chatReminderAt, t, command.title)
            }
            return String(format: s.chatReminderAbout, command.title)
        }
        if command.actionType == .calendarEvent {
            if let when = command.startDate {
                let t = replyDateFormatter.string(from: when)
                return String(format: s.chatEventAt, command.title, t)
            }
            return String(format: s.chatEventCalendar, command.title)
        }
        return s.chatTryRemind
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
