import Foundation

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

    private let speechService = SpeechRecognizerService()

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
        Task { await speechService.cancelForReset() }
    }

    private func beginListening() async {
        if let err = await speechService.requestAuthorizationIfNeeded() {
            errorMessage = err
            flowState = .error
            return
        }

        displayedText = ""

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
                flowState = .success
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
            flowState = .error
        }
    }
}
