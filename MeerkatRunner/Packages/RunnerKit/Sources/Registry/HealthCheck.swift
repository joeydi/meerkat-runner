import Foundation

/// Health URLs (AGENTS.md §6.4): after a start, one successful GET marks the server up. 2xx–4xx count
/// as up (the server answered); each try has a 2 s timeout, retried for up to 60 s.
///
/// Loopback only: Runner makes no outbound requests other than Sparkle and links the user clicks
/// (§8.1 rule 7), so a health URL must point at this Mac. Redirects aren't followed.
public enum HealthCheck {
    public static let requestTimeout: TimeInterval = 2
    public static let retryWindow: Duration = .seconds(60)
    static let retryInterval: Duration = .seconds(1)

    /// `http(s)://localhost`, `127.0.0.1` or `[::1]`, any port and path.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// Parses what the user typed in the Add window. nil for empty or not allowed.
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), isAllowed(url) else { return nil }
        return url
    }

    /// True for statuses that mean the server answered.
    public static func isUp(status: Int) -> Bool {
        (200..<500).contains(status)
    }

    /// One GET. False on any error, timeout, or a URL that isn't loopback.
    static func probe(_ url: URL) async -> Bool {
        guard isAllowed(url) else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let http = response as? HTTPURLResponse
        else { return false }
        return isUp(status: http.statusCode)
    }

    /// Probes until one succeeds or `retryWindow` passes.
    static func waitUntilUp(_ url: URL) async -> Bool {
        let deadline = ContinuousClock.now + retryWindow
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await probe(url) { return true }
            try? await Task.sleep(for: retryInterval)
        }
        return false
    }

    /// A redirect is an answer: stop there rather than follow it (possibly off this Mac).
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
