import AVFoundation
import Foundation
import os.log

enum VocaTimeSpeechErrorCode: Int {
    case generic = 0
    case nothingToStop = 1
    case interrupted = 2
    case recordingFailed = 3
}

enum VocaTimeSpeechDomain {
    static let name = "VocaTimeSpeech"
}

private func speechRecognitionError(code: VocaTimeSpeechErrorCode, fallbackMessage: String) -> Error {
    NSError(domain: VocaTimeSpeechDomain.name, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: fallbackMessage])
}

/// Captures microphone audio to a temporary `.m4a` file. Transcription is done separately via `MultilingualTranscriptionService` (not Apple speech APIs).
@MainActor
final class SpeechRecognizerService {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Speech")

    private var audioRecorder: AVAudioRecorder?
    private var recordingFileURL: URL?

    /// Stops any in-flight session when the user dismisses the flow (e.g. Done).
    func cancelForReset() async {
        await cancelOngoingSessionSilently()
    }

    /// Microphone only (no `SFSpeechRecognizer` / Speech permission required for the command flow).
    func requestAuthorizationIfNeeded(messages: SpeechServiceMessages) async -> String? {
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
            return messages.micDeniedSettings
        case .denied, .restricted:
            return messages.micDenied
        @unknown default:
            return messages.micUnavailable
        }
    }

    /// Starts recording to a new temporary `.m4a` file. Returns an error string if setup fails.
    func startRecording(messages: SpeechServiceMessages) async -> String? {
        await cancelOngoingSessionSilently()

        let session = AVAudioSession.sharedInstance()
        do {
            // `.default` mode for plain recording; `.measurement` is tuned for live speech-recognition engines.
            try session.setCategory(.record, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return String(format: messages.micUseFailed, error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VocaTime-\(UUID().uuidString).m4a", isDirectory: false)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            try? session.setActive(false)
            return String(format: messages.audioStartFailed, error.localizedDescription)
        }
        guard recorder.prepareToRecord(), recorder.record() else {
            try? session.setActive(false)
            return String(format: messages.audioStartFailed, "Could not start recording.")
        }

        audioRecorder = recorder
        recordingFileURL = url
        Self.log.info("[Speech] recording started path=\(url.path, privacy: .public)")
        return nil
    }

    /// Stops recording and returns the finalized audio file URL (caller should delete after upload).
    func stopRecording() async -> Result<URL, Error> {
        guard let recorder = audioRecorder, let url = recordingFileURL else {
            return .failure(speechRecognitionError(code: .nothingToStop, fallbackMessage: "Nothing to stop — start listening first."))
        }

        recorder.stop()
        audioRecorder = nil
        recordingFileURL = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Self.log.info("[Speech] recording stopped path=\(url.path, privacy: .public) fileBytes=\(fileSize, privacy: .public)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.log.error("[Speech] recording file missing path=\(url.path, privacy: .public)")
            return .failure(speechRecognitionError(code: .recordingFailed, fallbackMessage: "Recording file missing."))
        }
        // A valid M4A container with real audio is always well above 10 KB.
        // A file ≤ 4096 bytes is an empty container header with no audio frames.
        guard fileSize > 4096 else {
            Self.log.error("[Speech] recording file too small (likely empty audio) fileBytes=\(fileSize, privacy: .public)")
            return .failure(speechRecognitionError(code: .recordingFailed, fallbackMessage: "Recording captured no audio — file too small (\(fileSize) bytes)."))
        }
        return .success(url)
    }

    private func cancelOngoingSessionSilently() async {
        if let recorder = audioRecorder {
            recorder.stop()
            audioRecorder = nil
        }
        if let url = recordingFileURL {
            try? FileManager.default.removeItem(at: url)
            recordingFileURL = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await Task.yield()
    }
}
