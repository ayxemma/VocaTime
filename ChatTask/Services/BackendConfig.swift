import Foundation

/// Central configuration for the ChatTask HTTP backend.
///
/// **Local development**
/// - **Simulator**: `http://127.0.0.1:<port>` or `http://localhost:<port>` reaches the host machine.
/// - **Physical device**: `localhost` is the phone itself — use your Mac’s LAN IP (e.g. `http://192.168.1.10:<port>`) or a deployed staging URL.
///
/// Override at runtime (highest priority) with the `CHATTASK_BACKEND_URL` environment variable
/// (e.g. Xcode scheme → Run → Arguments → Environment Variables).
enum BackendConfig {

    /// Default base URL when no override is set.
    /// - DEBUG: local backend placeholder (change port to match your server).
    /// - RELEASE: replace with your production API origin before shipping.
    #if DEBUG
    private static let defaultBaseURLString = "http://127.0.0.1:8787"
    #else
    private static let defaultBaseURLString = "https://api.chattask.app"
    #endif

    /// Resolved backend origin (no trailing slash).
    static var baseURL: URL {
        let trimmed = ProcessInfo.processInfo.environment["CHATTASK_BACKEND_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty, let url = URL(string: trimmed) {
            return url
        }
        guard let url = URL(string: defaultBaseURLString) else {
            fatalError("BackendConfig: invalid defaultBaseURLString")
        }
        return url
    }

    /// `POST` multipart audio → JSON `{ "text": "..." }`
    static var transcribeURL: URL {
        baseURL.appendingPathComponent("transcribe")
    }

    /// `POST` JSON body with `text`, `now`, `timezone`, optional `locale` → parsed command JSON
    static var parseURL: URL {
        baseURL.appendingPathComponent("parse")
    }
}
