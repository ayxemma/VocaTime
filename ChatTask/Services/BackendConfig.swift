import Foundation

/// Central configuration for the ChatTask HTTP backend.
///
/// The default API origin is the production deployment. Override at runtime (highest priority) with
/// the `CHATTASK_BACKEND_URL` environment variable (Xcode → Scheme → Run → Arguments → Environment
/// Variables), e.g. `http://127.0.0.1:8000` for a local server from the Simulator.
enum BackendConfig {

    /// Default API base when `CHATTASK_BACKEND_URL` is unset. Single source of truth — do not hardcode
    /// this URL elsewhere.
    private static let apiBaseURLString = "https://chattask-backend.onrender.com"

    /// Resolved backend origin (no trailing slash).
    static var baseURL: URL {
        let trimmed = ProcessInfo.processInfo.environment["CHATTASK_BACKEND_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, let url = URL(string: trimmed) {
            return url
        }
        guard let url = URL(string: apiBaseURLString) else {
            fatalError("BackendConfig: invalid apiBaseURLString")
        }
        return url
    }

    /// `GET` — used for silent warm-up (`/health`).
    static var healthURL: URL {
        baseURL.appendingPathComponent("health")
    }

    /// `POST` multipart audio → JSON `{ "text": "..." }`
    static var transcribeURL: URL {
        baseURL.appendingPathComponent("transcribe")
    }

    /// `POST` JSON: required `text`, `now`, `timezone`; optional `locale`, `request_id`; backend may accept `parse_instructions`, `source`.
    static var parseURL: URL {
        baseURL.appendingPathComponent("parse")
    }
}
