import Foundation

/// The Codex CLI's ChatGPT sign-in, read from `~/.codex/auth.json`.
///
/// Read-only, always. The CLI's refresh tokens are single-use, so this app
/// must never refresh: doing so would spend the CLI's refresh token and sign
/// the user out of Codex. An expired access token means "run `codex` once".
nonisolated struct CodexCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String
    /// The access token's JWT `exp`, when it can be read.
    let expiresAt: Int64?

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func parse(_ data: Data) -> CodexCredentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty
        else { return nil }
        return CodexCredentials(accessToken: access, accountID: account, expiresAt: jwtExpiry(access))
    }

    func isExpired(now: Int64) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    static func jwtExpiry(_ token: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = CodexRolloutParser.int64(CodexRolloutParser.number(claims["exp"]))
        else { return nil }
        return exp
    }
}

/// Opt-in live poll of the endpoint behind the Codex CLI's `/status` usage
/// readout. Verified 2026-10-07 against codex-cli 0.149.0 — see the design
/// spec (docs/superpowers/specs/2026-10-07-settings-window-and-codex-usage-design.md).
nonisolated enum CodexLiveClient {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    enum Failure: Error, Equatable, Sendable {
        /// No `auth.json`, or it holds no ChatGPT sign-in (e.g. API-key mode,
        /// or credentials kept in the Keychain).
        case noCredentials
        /// Token past its `exp`, or rejected with 401/403.
        case expired
        case http(Int)
        case badResponse
        case network(String)

        var message: String {
            switch self {
            case .noCredentials: return "No ChatGPT sign-in in ~/.codex/auth.json."
            case .expired: return "Codex sign-in expired — run `codex` once to refresh it."
            case .http(let code): return "Usage endpoint returned HTTP \(code)."
            case .badResponse: return "Usage endpoint returned an unexpected response."
            case .network(let m): return "Network error: \(m)"
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func request(for c: CodexCredentials) -> URLRequest {
        var r = URLRequest(url: usageURL, timeoutInterval: 20)
        r.httpMethod = "GET"
        r.setValue("Bearer \(c.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(c.accountID, forHTTPHeaderField: "chatgpt-account-id")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    static func readCredentials(at url: URL = CodexCredentials.defaultURL) -> CodexCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CodexCredentials.parse(data)
    }

    static func fetch(
        credentials: CodexCredentials?,
        now: Int64,
        transport: Transport = liveTransport
    ) async -> Result<CodexSnapshot, Failure> {
        guard let credentials else { return .failure(.noCredentials) }
        guard !credentials.isExpired(now: now) else { return .failure(.expired) }
        do {
            let (data, status) = try await transport(request(for: credentials))
            switch status {
            case 200:
                return parseUsage(data, observedAt: now).map { .success($0) } ?? .failure(.badResponse)
            case 401, 403:
                return .failure(.expired)
            default:
                return .failure(.http(status))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Only `rate_limit` (the main Codex limit); `additional_rate_limits`
    /// are per-model limits, out of scope like their session-log twins.
    static func parseUsage(_ data: Data, observedAt: Int64) -> CodexSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any]
        else { return nil }
        let windows = ["primary_window", "secondary_window"].compactMap { key -> CodexWindow? in
            guard let w = rl[key] as? [String: Any],
                  let used = CodexRolloutParser.percent(CodexRolloutParser.number(w["used_percent"])),
                  let secs = CodexRolloutParser.int64(CodexRolloutParser.number(w["limit_window_seconds"])),
                  secs >= 60, secs <= 60_000_000,
                  let reset = CodexRolloutParser.int64(CodexRolloutParser.number(w["reset_at"]))
            else { return nil }
            return CodexWindow(usedPercent: used, windowMinutes: Int(secs / 60), resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        return CodexSnapshot(windows: windows, planType: obj["plan_type"] as? String,
                             observedAt: observedAt, source: .live)
    }
}
