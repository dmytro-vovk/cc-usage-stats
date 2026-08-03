import Foundation

/// Reads every rate-limit window from `GET /api/oauth/usage`.
///
/// Unlike the header path this is a plain GET: it costs no quota, and it is
/// the only source that exposes per-model weekly windows.
struct OAuthUsageClient: AnthropicAPIClient {
    let provider: OAuthTokenProvider
    let session: URLSession

    init(provider: OAuthTokenProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func fetchRateLimits() async -> AnthropicAPI.Result {
        let token: String
        switch await provider.accessToken() {
        case .token(let t):
            token = t
        case .unusable:
            // No session, or the grant is permanently gone. The caller
            // treats this as "fall back to headers and ask for a reconnect".
            return .insufficientScope
        case .temporarilyUnavailable(let why):
            // Offline or a 5xx on refresh. Must stay transient so the
            // offline detector still counts it and the UI does not tell the
            // user to reauthorize over a dropped Wi-Fi connection.
            return .transient("token refresh: \(why)")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .transient("no http response")
            }
            return OAuthUsage.parse(status: http.statusCode, body: data)
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
