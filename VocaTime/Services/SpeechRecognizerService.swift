import AVFoundation
import Foundation
import Speech

private func speechRecognitionError(_ message: String) -> Error {
    NSError(domain: "VocaTimeSpeech", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Streams microphone audio to on-device/server speech recognition. All public methods and callbacks are main-actor isolated.
@MainActor
final class SpeechRecognizerService {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var onPartialResult: ((String) -> Void)?
    private var onRuntimeError: ((String) -> Void)?

    private var lastTranscript: String = ""
    private var isStopping = false
    private var stopContinuation: CheckedContinuation<Result<String, Error>, Never>?
    private var stopTimeoutTask: Task<Void, Never>?

    /// Stops any in-flight session when the user dismisses the flow (e.g. Done).
    func cancelForReset() async {
        await cancelOngoingSessionSilently()
    }

    /// Returns `nil` if authorized (or became authorized), otherwise a user-readable error.
    func requestAuthorizationIfNeeded() async -> String? {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            let newStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if newStatus != .authorized {
                return speechAuthErrorMessage(for: newStatus)
            }
        case .denied, .restricted:
            return speechAuthErrorMessage(for: speechStatus)
        @unknown default:
            return "Speech recognition is not available."
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if granted {
                return nil
            }
            return "Microphone access was denied. Enable it in Settings → Privacy → Microphone."
        case .denied, .restricted:
            return "Microphone access is denied. Enable it in Settings → Privacy → Microphone."
        @unknown default:
            return "Microphone is not available."
        }
    }

    /// Starts capturing audio and recognition. Returns an immediate error string if setup fails; otherwise `nil`.
    func startRecognition(
        onPartialResult: @escaping (String) -> Void,
        onRuntimeError: @escaping (String) -> Void
    ) async -> String? {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            return "Speech recognition isn’t available right now. Check your network or try again later."
        }

        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        await cancelOngoingSessionSilently()

        self.onPartialResult = onPartialResult
        self.onRuntimeError = onRuntimeError
        lastTranscript = ""
        isStopping = false

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return "Could not use the microphone: \(error.localizedDescription)"
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            try? session.setActive(false)
            return "Microphone input isn’t available on this device."
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine = engine
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleRecognitionCallback(recognitionResult: result, error: error)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanupAfterFailedStart()
            return "Could not start audio: \(error.localizedDescription)"
        }

        return nil
    }

    /// Ends audio input and waits for a final transcript (or timeout using the last partial result).
    func stopRecognition() async -> Result<String, Error> {
        guard audioEngine != nil || recognitionTask != nil else {
            return .failure(speechRecognitionError("Nothing to stop — start listening first."))
        }

        isStopping = true
        recognitionRequest?.endAudio()
        removeTapAndStopEngine()

        return await withCheckedContinuation { continuation in
            stopContinuation = continuation

            stopTimeoutTask?.cancel()
            stopTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self.finishStopIfNeeded(
                    outcome: .success(self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
                )
            }
        }
    }

    private func handleRecognitionCallback(recognitionResult: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            let ns = error as NSError
            if isStopping, ns.domain == "kAFAssistantErrorDomain", ns.code == 216 {
                finishStopIfNeeded(outcome: .success(lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }
            if isStopping {
                let trimmed = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    finishStopIfNeeded(outcome: .failure(error))
                } else {
                    finishStopIfNeeded(outcome: .success(trimmed))
                }
                return
            }
            onRuntimeError?(userFacingRecognitionError(error))
            teardownAfterFailure()
            return
        }

        guard let recognitionResult else { return }

        let text = recognitionResult.bestTranscription.formattedString
        lastTranscript = text
        onPartialResult?(text)

        if recognitionResult.isFinal {
            if isStopping {
                finishStopIfNeeded(outcome: .success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                onRuntimeError?(
                    "Recognition ended early (often after a long pause). Tap the microphone to start again."
                )
                teardownAfterFailure()
            }
        }
    }

    private func finishStopIfNeeded(outcome: Result<String, Error>) {
        guard let cont = stopContinuation else { return }
        stopContinuation = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        cont.resume(returning: outcome)
        fullTeardown()
    }

    private func removeTapAndStopEngine() {
        let engine = audioEngine
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
    }

    private func teardownAfterFailure() {
        if let cont = stopContinuation {
            cont.resume(returning: .failure(speechRecognitionError("Recognition stopped.")))
        }
        stopContinuation = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        fullTeardown()
    }

    private func cleanupAfterFailedStart() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        audioEngine = nil
        onPartialResult = nil
        onRuntimeError = nil
        isStopping = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fullTeardown() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        onPartialResult = nil
        onRuntimeError = nil
        isStopping = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cancelOngoingSessionSilently() async {
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        if let cont = stopContinuation {
            cont.resume(returning: .failure(speechRecognitionError("Interrupted.")))
        }
        stopContinuation = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        audioEngine = nil
        onPartialResult = nil
        onRuntimeError = nil
        isStopping = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await Task.yield()
    }

    private func speechAuthErrorMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "Speech recognition is turned off. Enable it in Settings → Privacy → Speech Recognition."
        case .restricted:
            return "Speech recognition is restricted on this device."
        case .notDetermined:
            return "Speech recognition permission is required."
        default:
            return "Speech recognition isn’t allowed."
        }
    }

    private func userFacingRecognitionError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "kAFAssistantErrorDomain", ns.code == 203 {
            return "No speech was detected. Try again and speak a bit closer to the microphone."
        }
        if ns.domain == "kAFAssistantErrorDomain", ns.code == 216 {
            return "Recognition was canceled."
        }
        return "Speech recognition failed: \(error.localizedDescription)"
    }
}
