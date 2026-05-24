import Foundation
import os.log

// MARK: - Protocol (for dependency injection / testing)

/// Abstracts the cloud transcription call so `VoiceCommandViewModel` can be tested without
/// real network access. `MultilingualTranscriptionService` is the production implementation.
protocol FallbackTranscribing {
    func transcribe(audioFileURL: URL) async throws -> String
}

// MARK: - Errors

enum MultilingualTranscriptionError: Error {
    case fileReadFailed(underlying: Error, requestId: UUID)
    case fileEmpty(requestId: UUID)
    case networkError(underlying: Error, requestId: UUID)
    case httpError(statusCode: Int, body: String, requestId: UUID)
    case decodingFailed(underlying: Error, rawBody: String, requestId: UUID)
}

/// Uploads recorded audio to the ChatTask backend `POST /transcribe` endpoint.
/// Conforms to `FallbackTranscribing` — used as the cloud fallback when local Apple speech
/// recognition is unavailable or the transcript quality check fails.
struct MultilingualTranscriptionService: FallbackTranscribing {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Transcription")

    // MARK: - Transcription

    /// Reads audio from disk and returns the transcript string from the backend JSON `{ "text": "..." }`.
    func transcribe(audioFileURL: URL) async throws -> String {
        let cloudT0 = CFAbsoluteTimeGetCurrent()
        BackendWarmup.scheduleSessionWarmup() // coalesced with app lifecycle warm-up
        let requestId = UUID()
        let session = await VoiceCommandLatencyTrace.active
        let commandSessionTag = session?.sessionTag ?? "none"
        await VoiceCommandLatencyTrace.recordTranscribeBackendCall()

        let endpoint = BackendConfig.transcribeURL
        Self.log.info("[Transcription] requestId=\(requestId.uuidString, privacy: .public) commandSessionId=\(commandSessionTag, privacy: .public) transcriptionUploadStart backendBaseURL=\(BackendConfig.baseURL.absoluteString, privacy: .public)")

        // ── 1. Audio file ───────────────────────────────────────────────────────
        let audioData: Data
        let fileReadT0 = CFAbsoluteTimeGetCurrent()
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=fileReadFailed path=\(audioFileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw MultilingualTranscriptionError.fileReadFailed(underlying: error, requestId: requestId)
        }
        Self.log.info("[Transcription] latency fileRead ms=\(Int((CFAbsoluteTimeGetCurrent() - fileReadT0) * 1000), privacy: .public)")

        guard !audioData.isEmpty else {
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=fileEmpty path=\(audioFileURL.path, privacy: .public)")
            throw MultilingualTranscriptionError.fileEmpty(requestId: requestId)
        }
        guard audioData.count > 4096 else {
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=fileTooSmall audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public) — likely empty-container M4A with no audio frames")
            throw MultilingualTranscriptionError.fileEmpty(requestId: requestId)
        }

        await MainActor.run {
            session?.audioFileSizeBytes = audioData.count
        }
        Self.log.info("[Transcription] audioFileSizeBytes=\(audioData.count, privacy: .public) commandSessionId=\(commandSessionTag, privacy: .public)")
        Self.log.info("[Transcription] requestId=\(requestId.uuidString, privacy: .public) audioReady audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public) ext=\(audioFileURL.pathExtension, privacy: .public)")

        // ── 2. Multipart body ───────────────────────────────────────────────────
        let multipartT0 = CFAbsoluteTimeGetCurrent()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ s: String) {
            if let d = s.data(using: .utf8) { body.append(d) }
        }

        let ext = audioFileURL.pathExtension.lowercased()
        let (mimeType, uploadFilename): (String, String) = {
            switch ext {
            case "wav":  return ("audio/wav",  "recording.wav")
            case "flac": return ("audio/flac", "recording.flac")
            case "mp3":  return ("audio/mpeg", "recording.mp3")
            case "m4a":  return ("audio/mp4",  "recording.m4a")
            default:     return ("audio/mp4",  "recording.m4a")
            }
        }()

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFilename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        BackendCorrelation.applyTracingHeaders(to: &request, requestId: requestId, commandSessionId: session?.sessionTag)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        Self.log.info("[Transcription] latency multipartBuild ms=\(Int((CFAbsoluteTimeGetCurrent() - multipartT0) * 1000), privacy: .public)")
        Self.log.info("[Transcription] requestId=\(requestId.uuidString, privacy: .public) uploading mimeType=\(mimeType, privacy: .public) bodyBytes=\(body.count, privacy: .public)")

        // ── 3. Send ───────────────────────────────────────────────────────────────
        let data: Data
        let response: URLResponse
        let networkT0 = CFAbsoluteTimeGetCurrent()
        do {
            // `POST /transcribe` not assumed idempotent: no HTTP 502/503 retry; transport errors may retry once.
            (data, response) = try await BackendFetchRetry.data(for: request, isIdempotent: false)
        } catch {
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=networkError error=\(String(describing: error), privacy: .public)")
            if let urlError = error as? URLError {
                Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) urlError code=\(urlError.code.rawValue, privacy: .public) — if backend is down, wrong URL, or ATS blocked HTTP, check Console and BackendConfig / Info.plist NSAllowsLocalNetworking")
            }
            throw MultilingualTranscriptionError.networkError(underlying: error, requestId: requestId)
        }
        let uploadMs = Int((CFAbsoluteTimeGetCurrent() - networkT0) * 1000)
        Self.log.info("[Transcription] transcriptionUploadMs=\(uploadMs, privacy: .public) latency transcribeNetwork ms=\(uploadMs, privacy: .public)")

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"

        Self.log.info("[Transcription] transcriptionResponseReceived requestId=\(requestId.uuidString, privacy: .public) httpStatus=\(status, privacy: .public) responseBytes=\(data.count, privacy: .public)")

        guard (200...299).contains(status) else {
            let truncatedBody = String(rawBody.prefix(1000))
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=http\(status, privacy: .public) responseBody=\(truncatedBody, privacy: .public)")
            throw MultilingualTranscriptionError.httpError(statusCode: status, body: truncatedBody, requestId: requestId)
        }

        // ── 4. Decode `{ "text": "..." }` ───────────────────────────────────────
        struct BackendTranscriptionResponse: Decodable {
            let text: String
        }

        let decoded: BackendTranscriptionResponse
        do {
            decoded = try JSONDecoder().decode(BackendTranscriptionResponse.self, from: data)
        } catch {
            let truncatedBody = String(rawBody.prefix(1000))
            Self.log.error("[Transcription] requestId=\(requestId.uuidString, privacy: .public) transcriptionFailureRootCause=decodingFailed error=\(String(describing: error), privacy: .public) rawBody=\(truncatedBody, privacy: .public)")
            throw MultilingualTranscriptionError.decodingFailed(underlying: error, rawBody: truncatedBody, requestId: requestId)
        }

        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - cloudT0) * 1000)
        Self.log.info("[Transcription] cloudTranscriptionTotalMs=\(totalMs, privacy: .public) transcriptLength=\(text.count, privacy: .public) commandSessionId=\(commandSessionTag, privacy: .public)")
        Self.log.info("[Transcription] requestId=\(requestId.uuidString, privacy: .public) requestSucceeded transcriptLength=\(text.count, privacy: .public)")
        Self.log.info("[Transcription] latency transcribe totalMs=\(totalMs, privacy: .public)")
        return text
    }
}
