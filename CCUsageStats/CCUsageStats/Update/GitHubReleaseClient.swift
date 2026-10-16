import Foundation

/// One answer from the releases endpoint.
nonisolated enum UpdateFetchResult: Equatable {
    case release(LatestRelease)
    /// GitHub refused for quota (unauthenticated: 60 requests an hour per IP,
    /// shared with everything else on the network). `retryAfter` is GitHub's
    /// own hint, in seconds, when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Network error, non-2xx, or a body that isn't a usable release.
    case failure
}

/// Fetches the latest release. Tests inject a stub.
protocol UpdateCheckClient {
    func fetchLatest() async -> UpdateFetchResult
}

/// Live client for `GET /repos/<owner>/<repo>/releases/latest`.
nonisolated struct GitHubReleaseClient: UpdateCheckClient {
    let session: URLSession
    let url: URL
    let userAgent: String

    /// Ephemeral: no shared cookie jar or URL cache rides along to GitHub.
    private static let ephemeral = URLSession(configuration: .ephemeral)

    init(session: URLSession = GitHubReleaseClient.ephemeral, url: URL = GitHubReleaseClient.defaultURL(), userAgent: String) {
        self.session = session
        self.url = url
        self.userAgent = userAgent
    }

    /// Production endpoint, with a `CCUS_RELEASES_URL` override for manual
    /// testing (`file:///tmp/latest.json` fakes a newer release).
    static func defaultURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CCUS_RELEASES_URL"], let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://api.github.com/repos/dmytro-vovk/cc-usage-stats/releases/latest")!
    }

    func fetchLatest() async -> UpdateFetchResult {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return .failure }
        // file:// (manual testing) has no HTTP status; take the body as is.
        guard let http = resp as? HTTPURLResponse else {
            return LatestRelease.parse(data).map(UpdateFetchResult.release) ?? .failure
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return Self.classify(status: http.statusCode, headers: headers, body: data,
                             now: Int64(Date().timeIntervalSince1970))
    }

    /// Pure: turn a response into a result. GitHub signals quota exhaustion
    /// with 429, or 403 plus `x-ratelimit-remaining: 0` / `retry-after`; a 403
    /// with quota left is some other refusal and just a failure.
    static func classify(status: Int, headers: [String: String], body: Data, now: Int64) -> UpdateFetchResult {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        let retryAfter = h["retry-after"].flatMap(TimeInterval.init)
        let exhausted = h["x-ratelimit-remaining"] == "0"

        if status == 429 || (status == 403 && (exhausted || retryAfter != nil)) {
            if let retryAfter { return .rateLimited(retryAfter: max(0, retryAfter)) }
            if exhausted, let reset = h["x-ratelimit-reset"].flatMap(Int64.init) {
                return .rateLimited(retryAfter: TimeInterval(max(0, reset - now)))
            }
            return .rateLimited(retryAfter: nil)
        }
        guard (200...299).contains(status) else { return .failure }
        return LatestRelease.parse(body).map(UpdateFetchResult.release) ?? .failure
    }
}
