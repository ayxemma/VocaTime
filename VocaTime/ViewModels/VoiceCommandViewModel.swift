import Foundation

enum ReminderScheduleOutcome: Equatable {
    case none
    case succeeded(String)
    case failed(String)
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
    var flowState: VoiceFlowState = .idle
    var displayedText: String = ""
    var errorMessage: String?
    var parsedCommand: ParsedCommand?
    var reminderScheduleOutcome: ReminderScheduleOutcome = .none
    var isSchedulingReminder = false

    private let speechService = SpeechRecognizerService()
    private let reminderService = ReminderService()

    func microphoneTapped() {
        errorMessage = nil
        switch flowState {
        case .idle, .success, .error:
            Task { await beginListening() }
        case .listening:
            Task { await finalizeListening() }
        case .processing:
            break
        }
    }

    func primaryActionTapped() {
        errorMessage = nil
        switch flowState {
        case .success, .error:
            reset()
        case .idle:
            errorMessage = "Tap the microphone to speak first."
            flowState = .error
        case .listening:
            errorMessage = "Tap the microphone again when you’re done speaking."
            flowState = .error
        case .processing:
            errorMessage = "Please wait until processing finishes."
            flowState = .error
        }
    }

    func reset() {
        flowState = .idle
        displayedText = ""
        errorMessage = nil
        parsedCommand = nil
        reminderScheduleOutcome = .none
        isSchedulingReminder = false
        Task { await speechService.cancelForReset() }
    }

    func createReminder() {
        reminderScheduleOutcome = .none
        guard let cmd = parsedCommand, cmd.actionType == .reminder else {
            reminderScheduleOutcome = .failed("This command isn’t a reminder.")
            return
        }
        guard let when = cmd.reminderDate else {
            reminderScheduleOutcome = .failed("No reminder time found. Try something like “in 5 minutes.”")
            return
        }
        guard !isSchedulingReminder else { return }
        isSchedulingReminder = true
        Task { @MainActor in
            defer { isSchedulingReminder = false }
            let result = await reminderService.scheduleReminder(
                title: cmd.title,
                notes: cmd.notes,
                at: when
            )
            switch result {
            case .success:
                let whenText = Self.reminderFeedbackFormatter.string(from: when)
                reminderScheduleOutcome = .succeeded("Reminder scheduled for \(whenText).")
            case .failure(let error):
                reminderScheduleOutcome = .failed(error.localizedDescription)
            }
        }
    }

    private static let reminderFeedbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func beginListening() async {
        if let err = await speechService.requestAuthorizationIfNeeded() {
            errorMessage = err
            flowState = .error
            return
        }

        displayedText = ""
        parsedCommand = nil
        reminderScheduleOutcome = .none

        let startError = await speechService.startRecognition(
            onPartialResult: { [weak self] text in
                self?.displayedText = text
            },
            onRuntimeError: { [weak self] message in
                guard let self else { return }
                self.errorMessage = message
                self.flowState = .error
            }
        )

        if let startError {
            errorMessage = startError
            flowState = .error
            return
        }

        flowState = .listening
    }

    private func finalizeListening() async {
        flowState = .processing
        let outcome = await speechService.stopRecognition()
        switch outcome {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                displayedText = ""
                errorMessage = "No words were recognized. Try speaking a bit longer or check the microphone."
                flowState = .error
            } else {
                displayedText = trimmed
                applyParseResult(for: trimmed)
            }
        case .failure(let error):
            let message = error.localizedDescription
            let trimmed = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                errorMessage = message
            } else {
                displayedText = trimmed
                errorMessage = message
            }
            parsedCommand = nil
            flowState = .error
        }
    }

    private func applyParseResult(for transcript: String) {
        let parser = IntentParserService(referenceDate: Date())
        switch parser.parse(transcript) {
        case .success(let command):
            parsedCommand = command
            flowState = .success
        case .failure(let error):
            parsedCommand = nil
            errorMessage = error.localizedDescription
            flowState = .error
        }
    }
}
