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

/// Captures microphone audio to a temporary `.m4a` file.
/// Silence-based auto-stop is handled internally via `AVAudioRecorder` metering (no speech-recognition callbacks needed).
@MainActor
final class SpeechRecognizerService {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Speech")

    // MARK: - Silence detection tuning
    /// Audio level (dBFS) above which input is treated as speech. –40 dB catches normal to quiet speech.
    private static let speechThreshold: Float = -40.0
    /// Consecutive seconds below `speechThreshold` — after speech has started — before auto-stop fires.
    private static let silenceDurationToStop: Double = 1.2
    /// Metering poll interval.
    private static let meterPollNanoseconds: UInt64 = 100_000_000  // 100 ms

    // MARK: - State
    private var audioRecorder: AVAudioRecorder?
    private var recordingFileURL: URL?
    private var meteringTask: Task<Void, Never>?
    /// Stored on the actor so the metering Task (also @MainActor) can call it without Sendability issues.
    private var autoStopCallback: (() -> Void)?

    // MARK: - Public API

    /// Stops any in-flight session when the user dismisses the flow.
    func cancelForReset() async {
        await cancelOngoingSessionSilently()
    }

    /// Microphone permission only (Speech Recognition not required for this recording path).
    func requestAuthorizationIfNeeded(messages: SpeechServiceMessages) async -> String? {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            return granted ? nil : messages.micDeniedSettings
        case .denied, .restricted:
            return messages.micDenied
        @unknown default:
            return messages.micUnavailable
        }
    }

    /// Starts recording to a temporary `.m4a` file. Returns a non-nil error string if setup fails.
    /// - Parameter onAutoStop: Called on the Main Actor when silence-based auto-stop triggers.
    func startRecording(messages: SpeechServiceMessages, onAutoStop: (() -> Void)?) async -> String? {
        await cancelOngoingSessionSilently()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return String(format: messages.micUseFailed, error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaTime-\(UUID().uuidString).m4a", isDirectory: false)
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

        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            try? session.setActive(false)
            return String(format: messages.audioStartFailed, "Could not start recording.")
        }

        audioRecorder = recorder
        recordingFileURL = url
        autoStopCallback = onAutoStop
        Self.log.info("[Speech] recording started path=\(url.path, privacy: .public)")

        startMeteringTask()
        return nil
    }

    /// Stops recording and returns the finalized audio file URL (caller must delete after use).
    func stopRecording() async -> Result<URL, Error> {
        guard let recorder = audioRecorder, let url = recordingFileURL else {
            return .failure(speechRecognitionError(code: .nothingToStop,
                                                   fallbackMessage: "Nothing to stop — start listening first."))
        }

        stopMeteringTask()
        recorder.stop()
        audioRecorder = nil
        recordingFileURL = nil
        autoStopCallback = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Self.log.info("[Speech] recording finalized path=\(url.path, privacy: .public) fileBytes=\(fileSize, privacy: .public)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.log.error("[Speech] recording file missing path=\(url.path, privacy: .public)")
            return .failure(speechRecognitionError(code: .recordingFailed, fallbackMessage: "Recording file missing."))
        }
        // A valid M4A container with real audio is always > 4 KB; anything smaller is an empty header.
        guard fileSize > 4096 else {
            Self.log.error("[Speech] recording file too small — likely empty audio fileBytes=\(fileSize, privacy: .public)")
            return .failure(speechRecognitionError(code: .recordingFailed,
                                                   fallbackMessage: "Recording captured no audio — file too small (\(fileSize) bytes)."))
        }
        return .success(url)
    }

    // MARK: - Silence detection

    private func startMeteringTask() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var hasSpeech = false
            var silenceStartedAt: Date? = nil
            var lastLoggedState: String = "pre-speech"

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SpeechRecognizerService.meterPollNanoseconds)
                guard !Task.isCancelled else { break }
                guard let self, let recorder = self.audioRecorder else { break }

                recorder.updateMeters()
                let level = recorder.averagePower(forChannel: 0)
                let isSpeaking = level > SpeechRecognizerService.speechThreshold

                if isSpeaking {
                    // ── Speech frame ───────────────────────────────────────────
                    if !hasSpeech {
                        hasSpeech = true
                        SpeechRecognizerService.log.info("[Speech] speechDetected level=\(level, privacy: .public)dB")
                        lastLoggedState = "speaking"
                    }
                    if silenceStartedAt != nil {
                        silenceStartedAt = nil
                        if lastLoggedState != "speaking" {
                            SpeechRecognizerService.log.info("[Speech] speechResumed level=\(level, privacy: .public)dB — silence timer reset")
                            lastLoggedState = "speaking"
                        }
                    }
                } else {
                    // ── Below threshold ────────────────────────────────────────
                    guard hasSpeech else { continue }  // Ignore pre-speech ambient noise

                    if silenceStartedAt == nil {
                        silenceStartedAt = Date()
                        SpeechRecognizerService.log.info("[Speech] silenceStarted level=\(level, privacy: .public)dB")
                        lastLoggedState = "silence"
                    } else if let start = silenceStartedAt,
                              Date().timeIntervalSince(start) >= SpeechRecognizerService.silenceDurationToStop {
                        SpeechRecognizerService.log.info(
                            "[Speech] silenceThresholdReached duration=\(SpeechRecognizerService.silenceDurationToStop, privacy: .public)s level=\(level, privacy: .public)dB — triggering auto-stop"
                        )
                        self.autoStopCallback?()
                        break
                    }
                }
            }
        }
    }

    private func stopMeteringTask() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    // MARK: - Internal teardown

    private func cancelOngoingSessionSilently() async {
        stopMeteringTask()
        autoStopCallback = nil
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
