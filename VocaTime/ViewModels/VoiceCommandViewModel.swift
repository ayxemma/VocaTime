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
        case .processing:
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

    private func applyChatParse(transcript: String) async {
        Self.log.info("[VoiceChat] parse input appUILanguage=\(self.uiLanguage.rawValue, privacy: .public) transcript=\(transcript, privacy: .public)")
        let command = await parsingCoordinator.parse(
            text: transcript,
            now: Date(),
            localeIdentifier: uiLanguage.uiLocaleIdentifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        Self.log.info("[VoiceChat] parse outcome actionType=\(String(describing: command.actionType), privacy: .public) parserSource=\(String(describing: command.parserSource), privacy: .public) title=\(command.title, privacy: .public) (see [TaskParsing] routingDecision for local-vs-LLM path)")
        parsedCommand = command
        let reply = confirmationMessage(for: command, userTranscript: transcript)
        chatMessages.append(ChatMessage(role: .assistant, text: reply))
        if let ctx = persistenceContext {
            TaskItem.insertFromParsedCommand(command, context: ctx)
        }
        chatFlowState = .success
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
