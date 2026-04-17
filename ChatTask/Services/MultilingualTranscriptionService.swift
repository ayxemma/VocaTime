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
    /// Backend base URL could not be resolved (should not happen with valid defaults).
    case invalidBackendConfiguration
    case fileReadFailed(underlying: Error)
    case fileEmpty
    case networkError(underlying: Error)
    case httpError(statusCode: Int, body: String)
    case decodingFailed(underlying: Error, rawBody: String)
}

/// Uploads recorded audio to the ChatTask backend `POST /transcribe` endpoint.
/// Conforms to `FallbackTranscribing` — used as the cloud fallback when local Apple speech
/// recognition is unavailable or the transcript quality check fails.
struct MultilingualTranscriptionService: FallbackTranscribing {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Transcription")

    // MARK: - Transcription

    /// Reads audio from disk and returns the transcript string from the backend JSON `{ "text": "..." }`.
    func transcribe(audioFileURL: URL) async throws -> String {
        let endpoint = BackendConfig.transcribeURL
        Self.log.info("[Transcription] backendBaseURL=\(BackendConfig.baseURL.absoluteString, privacy: .public) transcribeURL=\(endpoint.absoluteString, privacy: .public)")

        // ── 1. Audio file ───────────────────────────────────────────────────────
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            Self.log.error("[Transcription] transcriptionFailureRootCause=fileReadFailed path=\(audioFileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw MultilingualTranscriptionError.fileReadFailed(underlying: error)
        }

        guard !audioData.isEmpty else {
            Self.log.error("[Transcription] transcriptionFailureRootCause=fileEmpty path=\(audioFileURL.path, privacy: .public)")
            throw MultilingualTranscriptionError.fileEmpty
        }
        guard audioData.count > 4096 else {
            Self.log.error("[Transcription] transcriptionFailureRootCause=fileTooSmall audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public) — likely empty-container M4A with no audio frames")
            throw MultilingualTranscriptionError.fileEmpty
        }

        Self.log.info("[Transcription] requestStart audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public)")

        // ── 2. Multipart body ───────────────────────────────────────────────────
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
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        Self.log.info("[Transcription] request mimeType=\(mimeType, privacy: .public) bodyBytes=\(body.count, privacy: .public)")

        // ── 3. Send ───────────────────────────────────────────────────────────────
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Self.log.error("[Transcription] transcriptionFailureRootCause=networkError error=\(String(describing: error), privacy: .public)")
            throw MultilingualTranscriptionError.networkError(underlying: error)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"

        Self.log.info("[Transcription] httpStatus=\(status, privacy: .public) responseBytes=\(data.count, privacy: .public)")

        guard (200...299).contains(status) else {
            let truncatedBody = String(rawBody.prefix(1000))
            Self.log.error("[Transcription] transcriptionFailureRootCause=http\(status, privacy: .public) responseBody=\(truncatedBody, privacy: .public)")
            throw MultilingualTranscriptionError.httpError(statusCode: status, body: truncatedBody)
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
            Self.log.error("[Transcription] transcriptionFailureRootCause=decodingFailed error=\(String(describing: error), privacy: .public) rawBody=\(truncatedBody, privacy: .public)")
            throw MultilingualTranscriptionError.decodingFailed(underlying: error, rawBody: truncatedBody)
        }

        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.info("[Transcription] succeeded transcriptLength=\(text.count, privacy: .public)")
        return text
    }
}
