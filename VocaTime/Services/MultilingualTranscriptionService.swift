import Foundation
import os.log

enum MultilingualTranscriptionError: Error {
    case missingAPIKey
    case fileReadFailed(underlying: Error)
    case fileEmpty
    case networkError(underlying: Error)
    case httpError(statusCode: Int, body: String)
    case decodingFailed(underlying: Error, rawBody: String)
}

/// Sends recorded audio to OpenAI's transcription API. Transcript is the source of truth for parsing (not `SFSpeechRecognizer`).
struct MultilingualTranscriptionService {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "Transcription")

    static let model = "gpt-4o-mini-transcribe"
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    // MARK: - API key

    /// `OPENAI_API_KEY` env first (e.g. Xcode scheme), then `Secrets.openAIAPIKey` for local dev. Returns `nil` when absent or placeholder.
    private static func resolvedAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        let s = Secrets.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "YOUR_API_KEY_HERE" { return nil }
        return s
    }

    // MARK: - Transcription

    /// Reads audio from disk and returns the transcript string from the API.
    func transcribe(audioFileURL: URL) async throws -> String {
        // ── 1. API key ─────────────────────────────────────────────────────────
        let apiKey: String
        if let k = Self.resolvedAPIKey() {
            apiKey = k
            Self.log.info("[Transcription] apiKeyFound=true")
        } else {
            Self.log.error("[Transcription] transcriptionFailureRootCause=missingAPIKey apiKeyFound=false — set OPENAI_API_KEY env var or fill in Secrets.openAIAPIKey")
            throw MultilingualTranscriptionError.missingAPIKey
        }

        // ── 2. Audio file ───────────────────────────────────────────────────────
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
        // A valid M4A with real audio frames is always > 4 KB. Anything smaller means
        // AVAudioRecorder wrote only the container header — no speech was captured.
        guard audioData.count > 4096 else {
            Self.log.error("[Transcription] transcriptionFailureRootCause=fileTooSmall audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public) — likely empty-container M4A with no audio frames")
            throw MultilingualTranscriptionError.fileEmpty
        }

        Self.log.info("[Transcription] audioBytes=\(audioData.count, privacy: .public) path=\(audioFileURL.path, privacy: .public)")

        // ── 3. Build request ────────────────────────────────────────────────────
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ s: String) {
            if let d = s.data(using: .utf8) { body.append(d) }
        }

        // File part — use `audio/mp4` (the correct IANA MIME type for M4A; `audio/m4a` is non-standard)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        // Model part
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(Self.model)\r\n")

        // Explicitly request plain JSON so decoding is predictable
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        Self.log.info("[Transcription] request endpoint=\(self.endpoint.absoluteString, privacy: .public) model=\(Self.model, privacy: .public) bodyBytes=\(body.count, privacy: .public)")

        // ── 4. Send ─────────────────────────────────────────────────────────────
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Self.log.error("[Transcription] transcriptionFailureRootCause=networkError error=\(String(describing: error), privacy: .public)")
            throw MultilingualTranscriptionError.networkError(underlying: error)
        }

        // ── 5. HTTP status ──────────────────────────────────────────────────────
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"

        Self.log.info("[Transcription] httpStatus=\(status, privacy: .public) responseBytes=\(data.count, privacy: .public)")

        guard (200...299).contains(status) else {
            let truncatedBody = String(rawBody.prefix(1000))
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let requestId = http?.value(forHTTPHeaderField: "x-request-id") ?? "unknown"
            Self.log.error("""
                [Transcription] transcriptionFailureRootCause=http\(status, privacy: .public) \
                httpStatus=\(status, privacy: .public) \
                contentType=\(contentType, privacy: .public) \
                x-request-id=\(requestId, privacy: .public) \
                responseBody=\(truncatedBody, privacy: .public)
                """)
            throw MultilingualTranscriptionError.httpError(statusCode: status, body: truncatedBody)
        }

        // ── 6. Decode ───────────────────────────────────────────────────────────
        struct OpenAITranscriptionJSON: Decodable {
            let text: String
        }

        let decoded: OpenAITranscriptionJSON
        do {
            decoded = try JSONDecoder().decode(OpenAITranscriptionJSON.self, from: data)
        } catch {
            let truncatedBody = String(rawBody.prefix(1000))
            Self.log.error("[Transcription] transcriptionFailureRootCause=decodingFailed error=\(String(describing: error), privacy: .public) rawBody=\(truncatedBody, privacy: .public)")
            throw MultilingualTranscriptionError.decodingFailed(underlying: error, rawBody: truncatedBody)
        }

        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.info("[Transcription] succeeded transcriptLength=\(text.count, privacy: .public) text=\(text, privacy: .public)")
        return text
    }
}
