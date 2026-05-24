import Foundation
import os.log

/// Wraps `URLSession` data tasks with a **single** retry for cold-start / gateway / transient network issues.
///
/// **Retry policy**
/// - `GET` / `HEAD` are always treated as safe to retry for HTTP `502` / `503` and selected `URLError`s.
/// - For other methods (e.g. `POST`), set `isIdempotent: true` only if the server guarantees
///   idempotency for that endpoint. When `isIdempotent` is `false`, HTTP `502`/`503` responses are
///   **not** retried (the request may have been accepted upstream); only transport-level `URLError`s
///   are retried once, where the first attempt likely never produced a response on the client.
enum BackendFetchRetry {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ChatTask", category: "BackendHTTP")
    private static let retryableHTTPStatuses: Set<Int> = [502, 503]
    private static let retryDelayNs: UInt64 = 1_500_000_000

    static func data(for request: URLRequest, isIdempotent: Bool) async throws -> (Data, URLResponse) {
        let method = (request.httpMethod ?? "GET").uppercased()
        let canRetryHTTPFailure = isIdempotent || method == "GET" || method == "HEAD"
        return try await performWithOptionalRetry(
            for: request,
            canRetryHTTPFailure: canRetryHTTPFailure
        )
    }

    private static func performWithOptionalRetry(
        for request: URLRequest,
        canRetryHTTPFailure: Bool
    ) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, retryableHTTPStatuses.contains(http.statusCode) {
                if canRetryHTTPFailure {
                    Self.log.info("Retrying once after HTTP \(http.statusCode) (possible cold start) requestId=\(request.value(forHTTPHeaderField: BackendCorrelation.requestIDHeaderField) ?? "none", privacy: .public) commandSessionId=\(request.value(forHTTPHeaderField: BackendCorrelation.commandSessionIDHeaderField) ?? "none", privacy: .public)")
                    try await Task.sleep(nanoseconds: Self.retryDelayNs)
                    return try await URLSession.shared.data(for: request)
                } else {
                    Self.log.info("Not retrying HTTP \(http.statusCode) — request not treated as idempotent (POST body may have been received) requestId=\(request.value(forHTTPHeaderField: BackendCorrelation.requestIDHeaderField) ?? "none", privacy: .public)")
                }
            }
            return (data, response)
        } catch {
            if Self.shouldRetryURLError(error) {
                Self.log.info("Retrying once after error (likely no complete response): \(String(describing: error), privacy: .public) requestId=\(request.value(forHTTPHeaderField: BackendCorrelation.requestIDHeaderField) ?? "none", privacy: .public) commandSessionId=\(request.value(forHTTPHeaderField: BackendCorrelation.commandSessionIDHeaderField) ?? "none", privacy: .public)")
                try await Task.sleep(nanoseconds: Self.retryDelayNs)
                return try await URLSession.shared.data(for: request)
            }
            throw error
        }
    }

    private static func shouldRetryURLError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
