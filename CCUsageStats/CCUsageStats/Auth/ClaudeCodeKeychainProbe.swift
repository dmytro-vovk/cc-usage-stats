import Foundation
import Security

/// One-shot best-effort read of an existing Claude Code OAuth token from macOS
/// Keychain. Returns nil if absent, denied, expired, or the value is not a
/// recognizable OAuth token. macOS surfaces a system access prompt the first
/// time another process queries one of those entries.
///
/// Claude Code no longer keeps a single credential item: recent builds write one
/// generic-password item per profile, named `Claude Code-credentials-<id>`, next
/// to the legacy bare `Claude Code-credentials`. Any of them may hold only an
/// `mcpOAuth` map with no claude.ai token at all, so every candidate is inspected
/// newest-first until one yields a usable token.
enum ClaudeCodeKeychainProbe {
    private static let servicePrefix = "Claude Code-credentials"

    /// A candidate keychain item: its service name, its modification date (the
    /// recency ranking key) and the decoded payload string.
    struct Entry {
        let service: String
        let modified: Date
        let payload: String
    }

    static func read(now: Date = Date()) -> String? {
        // `candidateAttributes()` is already newest-first; payloads are resolved on
        // demand so the access prompt stops as soon as one yields a usable token.
        firstUsableToken(candidates: candidateAttributes(), now: now) { attrs in
            guard let service = attrs[kSecAttrService as String] as? String else { return nil }
            return fetchPayload(service: service, account: attrs[kSecAttrAccount as String] as? String)
        }
    }

    /// Newest entry that actually yields a usable, unexpired token wins. Entries
    /// holding only `mcpOAuth`, an expired `claudeAiOauth`, or a non-OAuth token
    /// are skipped rather than ending the search.
    static func selectToken(from entries: [Entry], now: Date) -> String? {
        firstUsableToken(candidates: entries.sorted { $0.modified > $1.modified }, now: now) { $0.payload }
    }

    /// Shared traversal for `read()` and `selectToken(from:now:)`, so the tested
    /// path is the shipping path. `candidates` must already be newest-first, and
    /// `payload` is invoked at most once per candidate — it triggers a Keychain
    /// access prompt in the shipping caller.
    static func firstUsableToken<Candidate>(
        candidates: [Candidate],
        now: Date,
        payload: (Candidate) -> String?
    ) -> String? {
        // A plain loop, deliberately: `lazy.compactMap { … }.first` resolves the
        // winning candidate twice (`Collection.first` is `self[startIndex]` after
        // `startIndex` already ran the transform), which would prompt twice and
        // trap on the force-unwrap inside lazy compactMap if the repeat fetch fails.
        for candidate in candidates {
            guard let raw = payload(candidate),
                  let token = usableToken(in: raw, now: now) else { continue }
            return token
        }
        return nil
    }

    // MARK: - Keychain access

    /// Attributes of every generic-password item whose service name starts with
    /// the Claude Code prefix, newest first. Attribute-only queries do not
    /// trigger an access prompt; reading the data does.
    private static func candidateAttributes() -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items
            .filter { ($0[kSecAttrService as String] as? String)?.hasPrefix(servicePrefix) == true }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    private static func modificationDate(of attrs: [String: Any]) -> Date {
        attrs[kSecAttrModificationDate as String] as? Date ?? .distantPast
    }

    private static func fetchPayload(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Payload parsing

    private static func usableToken(in payload: String, now: Date) -> String? {
        // Bare token string.
        if payload.hasPrefix("sk-ant-") { return validated(payload) }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Current envelope: {"claudeAiOauth": {accessToken, expiresAt, …}, "mcpOAuth": {…}}.
        // An entry carrying only `mcpOAuth` falls through the legacy lookup and yields nil.
        if let oauth = obj["claudeAiOauth"] as? [String: Any] {
            return token(in: oauth, now: now)
        }
        return token(in: obj, now: now) // legacy flat envelope
    }

    private static func token(in obj: [String: Any], now: Date) -> String? {
        if let expiry = expiryDate(obj["expiresAt"]), expiry <= now { return nil }
        for key in ["accessToken", "access_token", "oauth_token", "token"] {
            if let v = obj[key] as? String { return validated(v) }
        }
        return nil
    }

    private static func validated(_ token: String) -> String? {
        token.hasPrefix("sk-ant-oat01-") ? token : nil
    }

    /// `expiresAt` is milliseconds since the epoch in current builds; a seconds
    /// value is tolerated so a unit mismatch can't read as "expired long ago",
    /// and a string-encoded value is parsed rather than failing open.
    private static func expiryDate(_ value: Any?) -> Date? {
        let parsed: Double? = switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
        guard let raw = parsed, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }
}
