import AVFoundation
import Foundation
import os.log
import Speech

// MARK: - Preserved error types (used by VoiceCommandViewModel for error-message routing)

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

// MARK: - New types for the local-first pipeline

enum SpeechState: Equatable {
    case idle
    case requestingPermission
    case listening
    case processing
    case finished
    case failed(String)
}

enum SpeechAutoStopBehavior: Equatable {
    case enabled
    case disabled
}

/// Result returned by `stopListening()`. Always includes the audio file URL even when a local
/// transcript is available — the file is needed for the cloud transcription fallback path.
struct LocalSpeechCaptureResult {
    let transcript: String
    let isFinal: Bool
    /// Average segment confidence from `SFSpeechRecognitionResult`; `nil` when recognition was
    /// unavailable or no segments were produced.
    let confidence: Float?
    /// URL of the uploadable recording file (M4A when export succeeds; WAV fallback).
    /// Caller is responsible for deleting after use.
    let audioURL: URL?
    let duration: TimeInterval
}

// MARK: - Protocol for dependency injection / testing

@MainActor
protocol SpeechManaging: AnyObject {
    var onPartialTranscript: ((String) -> Void)? { get set }
    var onFinalResult: ((LocalSpeechCaptureResult) -> Void)? { get set }
    var onStateChange: ((SpeechState) -> Void)? { get set }

    func requestAuthorizationIfNeeded(messages: SpeechServiceMessages) async -> String?
    func startListening(
        locale: Locale,
        messages: SpeechServiceMessages,
        autoStopBehavior: SpeechAutoStopBehavior,
        onAutoStop: (() -> Void)?
    ) async -> String?
    func stopListening(waitForLocalFinal: Bool) async -> Result<LocalSpeechCaptureResult, Error>
    func cancelForReset() async
}

// MARK: - Implementation

/*
 PIPELINE SUMMARY
 ─────────────────────────────────────────────────────────────────────────────
 • AVAudioEngine tap → SFSpeechAudioBufferRecognitionRequest + AVAudioFile (.wav).
 • stopListening(): stops engine, closes WAV immediately (recording finalized), ends audio on
   the recognition request, then in parallel: (a) AAC/M4A export for smaller cloud uploads,
   (b) adaptive wait for Apple final transcript — early exit when transcript is empty or below
   TranscriptionRouter.confidenceThreshold so cloud path is not blocked for ~2s unnecessarily.
 • High-confidence / final Apple results still wait for isFinal or full max wait when needed.
 • Upload prefers `recording.m4a`; falls back to WAV if export fails (backend accepts audio MIME types).
 ─────────────────────────────────────────────────────────────────────────────
*/

@MainActor
final class SpeechRecognizerService: SpeechManaging {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Speech")

    // MARK: - Silence detection tuning (preserved from original service)
    /// Audio level (dBFS) above which input is treated as speech. –40 dB catches normal to quiet speech.
    private static let speechThreshold: Float = -40.0
    /// Consecutive seconds below `speechThreshold` — after speech has started — before auto-stop fires
    /// in flows that opt in. Chat voice input disables this and uses tap-to-stop.
    private static let silenceDurationToStop: Double = 1.2
    /// Metering poll interval.
    private static let meterPollNanoseconds: UInt64 = 100_000_000  // 100 ms

    // MARK: - Callbacks

    var onPartialTranscript: ((String) -> Void)?
    var onFinalResult: ((LocalSpeechCaptureResult) -> Void)?
    var onStateChange: ((SpeechState) -> Void)?

    // MARK: - Audio engine state

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Written from the input-node tap (background thread). Marked unsafe because access is
    /// carefully ordered: tap writes while engine runs, main actor reads only after engine is stopped.
    nonisolated(unsafe) private var audioFile: AVAudioFile?
    private var recordingFileURL: URL?
    private var recordingStartTime: Date?

    // MARK: - Silence detection state

    private var meteringTask: Task<Void, Never>?
    private var autoStopCallback: (() -> Void)?
    /// Current audio power level, updated from the tap closure (background thread).
    /// Non-atomic but safe: worst case is a stale 100 ms reading, which is acceptable for metering.
    nonisolated(unsafe) private var lastBufferPowerLevel: Float = -160

    // MARK: - Recognition state

    private var currentBestTranscript: String = ""
    private var currentBestConfidence: Float? = nil
    /// Continuation held while `stopListening()` waits for Apple's "isFinal" result.
    private var pendingFinalContinuation: CheckedContinuation<String, Never>?
    private var speechRecognitionAvailable: Bool = false
    /// Whether the recognition callback delivered `result.isFinal` for this stop session.
    private var stopSessionReceivedAppleFinal: Bool = false

    // MARK: - Public API

    func cancelForReset() async {
        await cancelOngoingSessionSilently()
    }

    /// Requests microphone permission (required) and speech recognition permission (optional —
    /// degrades gracefully to audio-only if denied). Returns a non-nil error string only when the
    /// microphone is unavailable.
    func requestAuthorizationIfNeeded(messages: SpeechServiceMessages) async -> String? {
        let micError = await checkMicrophonePermission(messages: messages)
        if let err = micError { return err }

        // Speech recognition: denied → audio-only mode, not a fatal error for the voice flow.
        speechRecognitionAvailable = await checkSpeechRecognitionPermission(messages: messages)
        return nil
    }

    /// Starts live speech recognition + audio recording simultaneously.
    /// Returns a non-nil error string if setup fails.
    func startListening(
        locale: Locale,
        messages: SpeechServiceMessages,
        autoStopBehavior: SpeechAutoStopBehavior = .enabled,
        onAutoStop: (() -> Void)?
    ) async -> String? {
        await cancelOngoingSessionSilently()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return String(format: messages.micUseFailed, error.localizedDescription)
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        if inputFormat.sampleRate == 0 {
            try? session.setActive(false)
            return String(format: messages.micInputUnavailable, "")
        }

        // ── Recording file ────────────────────────────────────────────────────
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaTime-\(UUID().uuidString).wav")
        recordingFileURL = fileURL
        recordingStartTime = Date()

        do {
            // Write in the input's native format (float32 PCM).
            // AVAudioFile + .wav extension produces a valid RIFF/WAV container.
            // The processing format matches the tap buffer so no conversion is needed.
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
        } catch {
            try? session.setActive(false)
            return String(format: messages.audioStartFailed, error.localizedDescription)
        }

        // ── Speech recognition setup ──────────────────────────────────────────
        if speechRecognitionAvailable {
            let recognizer = SFSpeechRecognizer(locale: locale)
            if let recognizer, recognizer.isAvailable {
                speechRecognizer = recognizer
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                recognitionRequest = request
                startRecognitionTask(request: request)
                Self.log.info("[Speech] localRecognition started locale=\(locale.identifier, privacy: .public)")
            } else {
                speechRecognitionAvailable = false
                Self.log.warning("[Speech] SFSpeechRecognizer unavailable for locale=\(locale.identifier, privacy: .public) — audio-only mode")
            }
        } else {
            Self.log.info("[Speech] speechRecognitionAvailable=false — audio-only mode")
        }

        // ── Input tap: feeds recognizer + writes to file ──────────────────────
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            try? self.audioFile?.write(from: buffer)
            self.lastBufferPowerLevel = Self.computePowerLevel(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            try? session.setActive(false)
            return String(format: messages.audioStartFailed, error.localizedDescription)
        }

        autoStopCallback = autoStopBehavior == .enabled ? onAutoStop : nil
        currentBestTranscript = ""
        currentBestConfidence = nil
        stopSessionReceivedAppleFinal = false
        lastBufferPowerLevel = -160

        if autoStopBehavior == .enabled {
            startMeteringTask(autoStopEnabled: true)
        } else {
            Self.log.info("[Speech] autoSilenceDisabled — user-controlled stop mode")
        }
        Self.log.info("[Speech] listening started fileURL=\(fileURL.path, privacy: .public) autoStop=\(String(describing: autoStopBehavior), privacy: .public)")
        return nil
    }

    /// Stops listening and returns the local transcript plus the audio file URL (M4A when export succeeds).
    func stopListening(waitForLocalFinal: Bool = true) async -> Result<LocalSpeechCaptureResult, Error> {
        guard let engine = audioEngine, let wavURL = recordingFileURL else {
            return .failure(speechRecognitionError(
                code: .nothingToStop,
                fallbackMessage: "Nothing to stop — start listening first."
            ))
        }

        let stopT0 = CFAbsoluteTimeGetCurrent()
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        stopMeteringTask()
        autoStopCallback = nil

        // Stop the engine first (this flushes the tap and guarantees no more buffer writes).
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        Self.log.info("[Speech] engine stopped duration=\(duration, privacy: .public)s latency engineStop ms=\(Self.latencyMs(since: stopT0), privacy: .public)")

        // Close WAV immediately so export + disk state are valid without waiting on Apple Speech.
        let recCloseT0 = CFAbsoluteTimeGetCurrent()
        audioFile = nil
        Self.log.info("[Speech] latency recordingFinalize ms=\(Self.latencyMs(since: recCloseT0), privacy: .public)")

        let speechWaitT0 = CFAbsoluteTimeGetCurrent()
        async let m4aExportTask: URL? = exportWavToM4AForUploadIfPossible(wavURL: wavURL)

        let finalTranscript: String
        if speechRecognitionAvailable, let request = recognitionRequest {
            request.endAudio()
            if waitForLocalFinal {
                finalTranscript = await waitForFinalTranscript(maxWait: 2.0)
                Self.log.info("[Speech] localFinalTranscript=\(finalTranscript, privacy: .public) confidence=\(String(describing: self.currentBestConfidence), privacy: .public) appleFinal=\(self.stopSessionReceivedAppleFinal, privacy: .public)")
            } else {
                finalTranscript = currentBestTranscript
                Self.log.info("[Speech] localFinalWaitSkipped — cloud transcription authoritative confidence=\(String(describing: self.currentBestConfidence), privacy: .public) appleFinal=\(self.stopSessionReceivedAppleFinal, privacy: .public)")
            }
        } else {
            finalTranscript = currentBestTranscript
        }
        Self.log.info("[Speech] latency speechFinalWait ms=\(Self.latencyMs(since: speechWaitT0), privacy: .public)")

        let m4aURL = await m4aExportTask
        var uploadURL = wavURL
        if let m4aURL {
            try? FileManager.default.removeItem(at: wavURL)
            uploadURL = m4aURL
            let m4aBytes = (try? FileManager.default.attributesOfItem(atPath: m4aURL.path)[.size] as? Int) ?? 0
            Self.log.info("[Speech] uploadFormat=m4a uploadBytes=\(m4aBytes, privacy: .public)")
        } else {
            Self.log.info("[Speech] uploadFormat=wav m4aExportFailedOrSkipped=true")
        }

        // ── Teardown speech (after transcript + export readers no longer need engine state) ──
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        recordingFileURL = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // ── Validate file ─────────────────────────────────────────────────────
        guard FileManager.default.fileExists(atPath: uploadURL.path) else {
            Self.log.error("[Speech] recordingFileMissing path=\(uploadURL.path, privacy: .public)")
            return .failure(speechRecognitionError(code: .recordingFailed, fallbackMessage: "Recording file missing."))
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: uploadURL.path)[.size] as? Int) ?? 0
        Self.log.info("[Speech] recordingReady fileBytes=\(fileSize, privacy: .public) ext=\(uploadURL.pathExtension, privacy: .public)")

        // Float32 WAV / M4A: Anything ≤ 4 KB is effectively empty.
        guard fileSize > 4096 else {
            Self.log.error("[Speech] fileTooSmall — likely no audio captured fileBytes=\(fileSize, privacy: .public)")
            try? FileManager.default.removeItem(at: uploadURL)
            return .failure(speechRecognitionError(
                code: .recordingFailed,
                fallbackMessage: "Recording captured no audio — file too small (\(fileSize) bytes)."
            ))
        }

        Self.log.info("[Speech] latency stopListening totalMs=\(Self.latencyMs(since: stopT0), privacy: .public)")
        return .success(LocalSpeechCaptureResult(
            transcript: finalTranscript,
            isFinal: stopSessionReceivedAppleFinal,
            confidence: currentBestConfidence,
            audioURL: uploadURL,
            duration: duration
        ))
    }

    private static func latencyMs(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// AAC in M4A for smaller `/transcribe` uploads; returns nil on any failure (caller keeps WAV).
    private func exportWavToM4AForUploadIfPossible(wavURL: URL) async -> URL? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let outURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: outURL.path) {
            try? FileManager.default.removeItem(at: outURL)
        }
        let asset = AVURLAsset(url: wavURL)
        if #available(iOS 16.0, *) {
            let exportable = (try? await asset.load(.isExportable)) ?? false
            guard exportable else {
                Self.log.info("[Speech] m4aExport skip reason=notExportable")
                return nil
            }
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            Self.log.info("[Speech] m4aExport skip reason=noSession")
            return nil
        }
        session.outputURL = outURL
        session.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            Self.log.info("[Speech] m4aExport failed status=\(session.status.rawValue, privacy: .public) err=\(String(describing: session.error), privacy: .public)")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        let wavBytes = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        let m4aBytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Self.log.info("[Speech] latency wavToM4a ms=\(Self.latencyMs(since: t0), privacy: .public) wavBytes=\(wavBytes, privacy: .public) m4aBytes=\(m4aBytes, privacy: .public)")
        return outURL
    }

    // MARK: - Permission helpers

    private func checkMicrophonePermission(messages: SpeechServiceMessages) async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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

    /// Returns `true` if speech recognition was already authorized or the user grants it now.
    /// Never returns an error — denial degrades to audio-only mode silently.
    private func checkSpeechRecognitionPermission(messages: SpeechServiceMessages) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            Self.log.info("[Speech] speechRecognitionDenied — degrading to audio-only")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Recognition task

    private func startRecognitionTask(request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer = speechRecognizer else { return }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Recognition callbacks arrive on a background thread — dispatch to MainActor.
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString
                    let segments = result.bestTranscription.segments
                    let confidence: Float? = segments.isEmpty ? nil :
                        segments.map(\.confidence).reduce(0, +) / Float(segments.count)

                    self.currentBestTranscript = transcript
                    self.currentBestConfidence = confidence

                    if result.isFinal {
                        Self.log.info("[Speech] recognitionFinal transcript=\(transcript, privacy: .public)")
                        self.stopSessionReceivedAppleFinal = true
                        self.resumeFinalContinuation(with: transcript)
                        let captureResult = LocalSpeechCaptureResult(
                            transcript: transcript,
                            isFinal: true,
                            confidence: confidence,
                            audioURL: self.recordingFileURL,
                            duration: Date().timeIntervalSince(self.recordingStartTime ?? Date())
                        )
                        self.onFinalResult?(captureResult)
                    } else {
                        self.onPartialTranscript?(transcript)
                    }
                }

                if let error {
                    let nsErr = error as NSError
                    // Code 301 = "No speech detected" — normal for short pauses; not a true error.
                    let isNoSpeech = nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 1110
                    if !isNoSpeech {
                        Self.log.warning("[Speech] recognitionError=\(String(describing: error), privacy: .public)")
                    }
                    self.resumeFinalContinuation(with: self.currentBestTranscript)
                }
            }
        }
    }

    // MARK: - Final transcript waiter

    /// Waits for Apple `isFinal`, total cap `maxWait`, or early exit when cloud routing would reject the transcript anyway.
    private func waitForFinalTranscript(maxWait: TimeInterval) async -> String {
        if let task = recognitionTask,
           task.state == .completed || task.state == .canceling {
            return currentBestTranscript
        }

        return await withCheckedContinuation { continuation in
            pendingFinalContinuation = continuation
            Task { @MainActor in
                let start = CFAbsoluteTimeGetCurrent()
                let pollNs: UInt64 = 45_000_000
                while self.pendingFinalContinuation != nil {
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    if elapsed >= maxWait {
                        self.resumeFinalContinuation(with: self.currentBestTranscript)
                        return
                    }
                    let trimmed = self.currentBestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let conf = self.currentBestConfidence
                    // Unusable for local path → don't block cloud on a slow Apple final.
                    if elapsed >= 0.38 && trimmed.isEmpty {
                        Self.log.info("[Speech] earlyExitSpeechWait reason=empty elapsedMs=\(Int(elapsed * 1000), privacy: .public)")
                        self.resumeFinalContinuation(with: self.currentBestTranscript)
                        return
                    }
                    if elapsed >= 0.52, let c = conf, c < TranscriptionRouter.confidenceThreshold {
                        Self.log.info("[Speech] earlyExitSpeechWait reason=lowConfidence chars=\(trimmed.count, privacy: .public) conf=\(c, privacy: .public) elapsedMs=\(Int(elapsed * 1000), privacy: .public)")
                        self.resumeFinalContinuation(with: self.currentBestTranscript)
                        return
                    }
                    try? await Task.sleep(nanoseconds: pollNs)
                }
            }
        }
    }

    private func resumeFinalContinuation(with transcript: String) {
        guard let c = pendingFinalContinuation else { return }
        pendingFinalContinuation = nil
        c.resume(returning: transcript)
    }

    // MARK: - Silence detection (ported from AVAudioRecorder metering to buffer power levels)

    private func startMeteringTask(autoStopEnabled: Bool) {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            var hasSpeech = false
            var silenceStartedAt: Date? = nil
            var lastLoggedState = "pre-speech"

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SpeechRecognizerService.meterPollNanoseconds)
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let level = self.lastBufferPowerLevel
                let isSpeaking = level > SpeechRecognizerService.speechThreshold

                if isSpeaking {
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
                    guard hasSpeech else { continue }

                    if silenceStartedAt == nil {
                        silenceStartedAt = Date()
                        SpeechRecognizerService.log.info("[Speech] silenceStarted level=\(level, privacy: .public)dB")
                        lastLoggedState = "silence"
                    } else if let start = silenceStartedAt,
                              Date().timeIntervalSince(start) >= SpeechRecognizerService.silenceDurationToStop {
                        if autoStopEnabled {
                            SpeechRecognizerService.log.info(
                                "[Speech] silenceThresholdReached duration=\(SpeechRecognizerService.silenceDurationToStop, privacy: .public)s — triggering auto-stop"
                            )
                            self.autoStopCallback?()
                        } else {
                            SpeechRecognizerService.log.info(
                                "[Speech] silenceThresholdReached duration=\(SpeechRecognizerService.silenceDurationToStop, privacy: .public)s — ignored auto-stop disabled"
                            )
                        }
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

    // MARK: - Audio level helper

    /// Computes RMS power (dBFS) from the first channel of a PCM buffer.
    /// Called from the AVAudioEngine tap (background thread) — must be nonisolated.
    nonisolated private static func computePowerLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(count))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    // MARK: - Teardown

    private func cancelOngoingSessionSilently() async {
        stopMeteringTask()
        autoStopCallback = nil
        pendingFinalContinuation = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil

        // audioFile is nonisolated(unsafe) but tap is already removed above, so safe to nil here.
        audioFile = nil

        if let url = recordingFileURL {
            try? FileManager.default.removeItem(at: url)
            recordingFileURL = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await Task.yield()
    }
}
