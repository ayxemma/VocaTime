import Foundation
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
    var chatMessages: [ChatMessage] = []
    var chatFlowState: VoiceFlowState = .idle
    var chatDraftText: String = ""
    var parsedCommand: ParsedCommand?

    private let speechService = SpeechRecognizerService()
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
        switch chatFlowState {
        case .idle: return "Tap the microphone to speak."
        case .listening: return "Listening… tap again when you’re done."
        case .processing: return "Processing…"
        case .success: return "Ready for your next command."
        case .error: return "Something went wrong — try again."
        }
    }

    func chatMicrophoneTapped() {
        switch chatFlowState {
        case .idle, .success, .error:
            Task { await chatBeginListening() }
        case .listening:
            Task { await chatFinalizeListening() }
        case .processing:
            break
        }
    }

    private func resetSilenceTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            guard let self else { return }
            if self.chatFlowState == .listening {
                await self.chatFinalizeListening()
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
    }

    func chatBeginListening() async {
        cancelSilenceTimer()

        if let err = await speechService.requestAuthorizationIfNeeded() {
            chatMessages.append(ChatMessage(role: .assistant, text: err))
            chatFlowState = .error
            return
        }

        chatDraftText = ""

        let startError = await speechService.startRecognition(
            onPartialResult: { [weak self] text in
                self?.chatDraftText = text
                self?.resetSilenceTimer()
            },
            onRuntimeError: { [weak self] message in
                guard let self else { return }
                self.cancelSilenceTimer()
                self.chatMessages.append(ChatMessage(role: .assistant, text: message))
                self.chatFlowState = .error
            }
        )

        if let startError {
            chatMessages.append(ChatMessage(role: .assistant, text: startError))
            chatFlowState = .error
            return
        }

        chatFlowState = .listening
        resetSilenceTimer()
    }

    func chatFinalizeListening() async {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
        chatFlowState = .processing
        let outcome = await speechService.stopRecognition()
        switch outcome {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chatDraftText = ""
            if trimmed.isEmpty {
                chatMessages.append(
                    ChatMessage(role: .assistant, text: "I didn’t catch that. Try speaking a bit longer.")
                )
                chatFlowState = .error
            } else {
                chatMessages.append(ChatMessage(role: .user, text: trimmed))
                await applyChatParse(transcript: trimmed)
            }
        case .failure(let error):
            chatDraftText = ""
            chatMessages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            parsedCommand = nil
            chatFlowState = .error
        }
    }

    private func applyChatParse(transcript: String) async {
        let command = await parsingCoordinator.parse(
            text: transcript,
            now: Date(),
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        parsedCommand = command
        let reply = Self.confirmationMessage(for: command, userTranscript: transcript)
        chatMessages.append(ChatMessage(role: .assistant, text: reply))
        if let ctx = persistenceContext {
            TaskItem.insertFromParsedCommand(command, context: ctx)
        }
        chatFlowState = .success
    }

    private static func confirmationMessage(for command: ParsedCommand, userTranscript: String) -> String {
        if command.actionType == .unknown {
            let name = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? "your task" : "“\(name)”"
            return """
            I saved \(label), but I couldn’t confidently figure out a date or time from what you said.

            Open the task from Home or Calendar, tap it, and set the schedule (or leave it as Anytime) in the editor.
            """
        }

        let low = userTranscript.lowercased()
        if command.actionType == .reminder {
            if let n = extractLeadingMinutes(from: low) {
                return "Got it. I’ll remind you in \(n) minute\(n == 1 ? "" : "s")."
            }
            if let n = extractLeadingHours(from: low) {
                return "Got it. I’ll remind you in \(n) hour\(n == 1 ? "" : "s")."
            }
            if let when = command.reminderDate {
                let t = chatReplyFormatter.string(from: when)
                return "Got it. I’ll remind you at \(t) about “\(command.title)”."
            }
            return "Got it. I’ll remind you about “\(command.title)”."
        }
        if command.actionType == .calendarEvent {
            if let when = command.startDate {
                let t = chatReplyFormatter.string(from: when)
                return "Got it. I’ve noted “\(command.title)” for \(t)."
            }
            return "Got it. I’ve noted “\(command.title)” for your calendar."
        }
        return "I’m not sure how to schedule that yet. Try “remind me…” or “today at 3 PM…”."
    }

    private static func extractLeadingMinutes(from low: String) -> Int? {
        let ns = low as NSString
        guard let regex = try? NSRegularExpression(pattern: #"in\s+(\d+)\s+minutes?"#, options: .caseInsensitive),
              let m = regex.firstMatch(in: low, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: low),
              let n = Int(low[r]), n > 0
        else { return nil }
        return n
    }

    private static func extractLeadingHours(from low: String) -> Int? {
        let ns = low as NSString
        guard let regex = try? NSRegularExpression(pattern: #"in\s+(\d+)\s+hours?"#, options: .caseInsensitive),
              let m = regex.firstMatch(in: low, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: low),
              let n = Int(low[r]), n > 0
        else { return nil }
        return n
    }

    private static let chatReplyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
