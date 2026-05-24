import Foundation
import os.log

// MARK: - Session warm-up (single flight, one success per process)

/// Coordinates `GET /health` wake-up calls: at most one in-flight request, and no further work
/// after a successful health check for the lifetime of the process (until app restart).
private actor WarmupSessionCoordinator {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "BackendWarmup")

    private var hasCompletedHealthCheck2xx = false
    private var inFlight: Task<Void, Never>?

    /// Schedules a best-effort warm-up if the session has not already succeeded and no request is in flight.
    func schedule() {
        if hasCompletedHealthCheck2xx { return }
        if inFlight != nil { return }
        Self.log.info("[BackendWarmup] warmupScheduled reason=sessionNotYetWarm")
        inFlight = Task(priority: .utility) {
            await self.runSingleHealthRequest()
        }
    }

    private func runSingleHealthRequest() async {
        defer { inFlight = nil }
        let t0 = CFAbsoluteTimeGetCurrent()

        var request = URLRequest(url: BackendConfig.healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        // Warm-up is intentionally NOT routed through `BackendFetchRetry` — a single `GET` only.
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                hasCompletedHealthCheck2xx = true
                Self.log.info("[BackendWarmup] warmupSucceeded healthMs=\(ms, privacy: .public) — backend likely warm for voice/transcribe")
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.info("[BackendWarmup] warmupNon2xx healthMs=\(ms, privacy: .public) status=\(status, privacy: .public)")
            }
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            Self.log.info("[BackendWarmup] warmupFailed healthMs=\(ms, privacy: .public) error=\(String(describing: error), privacy: .public) — next voice request may hit cold start")
        }
    }
}

// MARK: - Public API

/// Fire-and-forget requests to `GET /health` so a cold-hosted backend (e.g. Render) can wake
/// before user-driven API traffic. Session-wide deduplication is enforced; real API calls use
/// ``BackendFetchRetry`` and must never share retry logic with warm-up.
enum BackendWarmup {

    private static let session = WarmupSessionCoordinator()

    /// Use from SwiftUI lifecycle (`.onAppear`, `ScenePhase.active`) and before backend work.
    /// Non-blocking, fire-and-forget; at most one concurrent warm-up; skips after a successful `2xx` health check this process.
    static func scheduleSessionWarmup() {
        Task(priority: .utility) {
            await session.schedule()
        }
    }

    /// Legacy name — forwards to ``scheduleSessionWarmup()``.
    static func warmUpBackendFireAndForget() {
        scheduleSessionWarmup()
    }
}
