import Foundation

protocol AnthropicAPIClient {
    func fetchRateLimits() async -> AnthropicAPI.Result
}

enum AnthropicAPI {
    enum Result: Equatable {
        case success(RateLimitsSnapshot)
        case invalidToken
        /// Token is valid but lacks `user:profile`, so /api/oauth/usage is
        /// refused. Distinct from `.invalidToken` because the same token
        /// still works on the response-header path.
        case insufficientScope
        /// A 200 with no usable window. `fiveHourIsAbsent`: the body still
        /// said outright that the account has no 5-hour limit, so a cached
        /// 5-hour window is no longer true.
        case notSubscriber(fiveHourIsAbsent: Bool)
        static var notSubscriber: Result { .notSubscriber(fiveHourIsAbsent: false) }
        case rateLimited
        case transient(String) // network, malformed body, 5xx, 4xx other
    }

    static func parse(status: Int, headers: [String: String], body: Data) -> Result {
        switch status {
        case 401:
            return .invalidToken
        case 403:
            // Same rule as the usage endpoint: only the API's own error
            // envelope is a verdict on the token.
            return isAPIError(body) ? .invalidToken : .transient("forbidden (not an API error)")
        case 429:
            return .rateLimited
        case 200:
            if let snap = parseHeaders(headers) {
                return .success(snap)
            }
            return .notSubscriber
        case 500...599:
            return .transient("server \(status)")
        default:
            return .transient("status \(status)")
        }
    }

    private static func parseHeaders(_ headers: [String: String]) -> RateLimitsSnapshot? {
        let lc = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }

        let five = window(headers: lc, suffix: "5h")
        let seven = window(headers: lc, suffix: "7d")
        if five == nil && seven == nil { return nil }
        // Weekly headers and no 5h header at all: the account has no 5-hour
        // limit. A partial or malformed 5h pair is a gap, not absence.
        let noFiveHeaders = lc["anthropic-ratelimit-unified-5h-utilization"] == nil
            && lc["anthropic-ratelimit-unified-5h-reset"] == nil
        return RateLimitsSnapshot(fiveHour: five, sevenDay: seven, fiveHourIsAbsent: seven != nil && noFiveHeaders)
    }

    /// `{"type":"error","error":{…}}` — what the API itself answers with, as
    /// opposed to a page or JSON from a WAF, proxy or VPN block in front of it.
    static func isAPIError(_ body: Data) -> Bool {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return envelope?["type"] as? String == "error" && envelope?["error"] is [String: Any]
    }

    private static func window(headers: [String: String], suffix: String) -> WindowSnapshot? {
        let utilKey = "anthropic-ratelimit-unified-\(suffix)-utilization"
        let resetKey = "anthropic-ratelimit-unified-\(suffix)-reset"
        guard let utilStr = headers[utilKey],
              let util = Double(utilStr), util.isFinite,
              let resetStr = headers[resetKey],
              let reset = Int64(resetStr) else {
            return nil
        }
        // Anthropic reports utilization as a fraction (0..1); we store percent.
        return WindowSnapshot(usedPercentage: util * 100.0, resetsAt: reset)
    }
}

struct LiveAnthropicAPIClient: AnthropicAPIClient {
    let token: String
    let session: URLSession
    let model: String

    init(token: String, session: URLSession = .shared, model: String = "claude-haiku-4-5") {
        self.token = token
        self.session = session
        self.model = model
    }

    func fetchRateLimits() async -> AnthropicAPI.Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") // REQUIRED for OAuth tokens
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transient("no http response") }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
                if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
            }
            return AnthropicAPI.parse(status: http.statusCode, headers: headers, body: data)
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
