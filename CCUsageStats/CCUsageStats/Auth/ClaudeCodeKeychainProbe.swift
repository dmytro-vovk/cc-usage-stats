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

    /// A token lifted out of Claude Code's Keychain together with the deadline
    /// the CLI recorded for it. `expiresAt` is nil for a bare-string payload or
    /// an envelope without `expiresAt`; callers treat that as "no known deadline".
    struct ImportedToken: Equatable {
        let token: String
        let expiresAt: Date?
    }

    /// What a probe actually found. The misses are separate cases because they
    /// call for different user actions — "expired 13h ago" means use the CLI or
    /// paste a durable token, "access denied" means click Allow and retry — and
    /// all of them used to collapse into one flat "no usable token" message.
    enum Outcome: Equatable {
        case found(ImportedToken)
        /// Every readable entry carrying a claude.ai token had lapsed. Carries
        /// the latest deadline seen, which is the one the user recognizes.
        case expired(Date)
        /// Entries exist but macOS wouldn't hand over their contents (denied or
        /// dismissed prompt). Blind, not empty-handed — so never reported as
        /// "nothing there".
        case accessDenied
        /// Entries were read but none holds a claude.ai OAuth token: `mcpOAuth`
        /// logins only, an API key, or an unrecognized shape.
        case noClaudeToken
        /// Claude Code has no credential items at all.
        case noEntries
    }

    /// One payload fetch. `denied` is distinct from `absent` so the traversal can
    /// tell "macOS said no" from "the item vanished between query and read", and
    /// `unreadable` keeps a corrupt-but-present item from being reported as an
    /// item that doesn't exist.
    enum PayloadFetch: Equatable {
        case body(String)
        case denied
        case unreadable
        case absent
    }

    /// Full diagnosis, including why a miss was a miss.
    static func probe(now: Date = Date()) -> Outcome {
        // `candidateAttributes()` is already newest-first; payloads are resolved on
        // demand so the access prompt stops as soon as one yields a usable token.
        classify(candidates: candidateAttributes(), now: now) { attrs in
            guard let service = attrs[kSecAttrService as String] as? String else { return .absent }
            return fetchPayload(service: service, account: attrs[kSecAttrAccount as String] as? String)
        }
    }

    /// Token-only view of `probe()`, for callers that only act on success.
    static func read(now: Date = Date()) -> ImportedToken? {
        guard case .found(let imported) = probe(now: now) else { return nil }
        return imported
    }

    /// Newest entry that actually yields a usable, unexpired token wins. Entries
    /// holding only `mcpOAuth`, an expired `claudeAiOauth`, or a non-OAuth token
    /// are skipped rather than ending the search.
    static func selectImport(from entries: [Entry], now: Date) -> ImportedToken? {
        guard case .found(let imported) = classifyEntries(entries, now: now) else { return nil }
        return imported
    }

    /// `classify` over a pre-fetched entry list — the offline form used by tests
    /// and by anything that already holds the payloads.
    static func classifyEntries(_ entries: [Entry], now: Date) -> Outcome {
        classify(candidates: entries.sorted { $0.modified > $1.modified }, now: now) { .body($0.payload) }
    }

    /// Token-only convenience over `selectImport(from:now:)`.
    static func selectToken(from entries: [Entry], now: Date) -> String? {
        selectImport(from: entries, now: now)?.token
    }

    /// Token-only convenience over `firstUsableImport(candidates:now:payload:)`.
    static func firstUsableToken<Candidate>(
        candidates: [Candidate],
        now: Date,
        payload: (Candidate) -> String?
    ) -> String? {
        firstUsableImport(candidates: candidates, now: now, payload: payload)?.token
    }

    /// Shared traversal for `read()` and `selectImport(from:now:)`, so the tested
    /// path is the shipping path. `candidates` must already be newest-first, and
    /// `payload` is invoked at most once per candidate — it triggers a Keychain
    /// access prompt in the shipping caller.
    static func firstUsableImport<Candidate>(
        candidates: [Candidate],
        now: Date,
        payload: (Candidate) -> String?
    ) -> ImportedToken? {
        let outcome = classify(candidates: candidates, now: now) { candidate in
            payload(candidate).map { PayloadFetch.body($0) } ?? .absent
        }
        guard case .found(let imported) = outcome else { return nil }
        return imported
    }

    /// The traversal, keeping the reason a miss was a miss.
    ///
    /// `candidates` must already be newest-first, and `payload` is invoked at
    /// most once per candidate — each call is a Keychain access prompt in the
    /// shipping caller.
    ///
    /// Miss precedence is deliberate: a denial outranks an expiry, because a
    /// denied item might have held a perfectly good token and reporting
    /// "expired" would send the user down the wrong path.
    static func classify<Candidate>(
        candidates: [Candidate],
        now: Date,
        payload: (Candidate) -> PayloadFetch
    ) -> Outcome {
        // A plain loop, deliberately: `lazy.compactMap { … }.first` resolves the
        // winning candidate twice (`Collection.first` is `self[startIndex]` after
        // `startIndex` already ran the transform), which would prompt twice and
        // trap on the force-unwrap inside lazy compactMap if the repeat fetch fails.
        var latestExpiry: Date?
        var sawDenial = false
        var sawEntry = false

        for candidate in candidates {
            switch payload(candidate) {
            case .denied:
                sawEntry = true
                sawDenial = true
            case .unreadable:
                // Present and permitted, just not something we can parse — the
                // user has a Claude Code credential, so "no credentials" would
                // be a lie.
                sawEntry = true
            case .absent:
                continue
            case .body(let raw):
                sawEntry = true
                switch inspect(payload: raw, now: now) {
                case .usable(let imported):
                    return .found(imported)
                case .expired(let deadline):
                    // Newest-first ordering usually puts the latest deadline
                    // first, but a stale item can carry a later expiry — take
                    // the max so the message quotes the freshest one.
                    latestExpiry = max(latestExpiry ?? deadline, deadline)
                case .unusable:
                    continue
                }
            }
        }

        if sawDenial { return .accessDenied }
        if let latestExpiry { return .expired(latestExpiry) }
        return sawEntry ? .noClaudeToken : .noEntries
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

    private static func fetchPayload(service: String, account: String?) -> PayloadFetch {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            // The read was allowed. Whether the bytes make sense is a separate
            // question, and answering it "the item isn't there" would be wrong.
            guard let data = result as? Data,
                  let payload = String(data: data, encoding: .utf8) else { return .unreadable }
            return .body(payload)
        }
        return isDenial(status) ? .denied : .absent
    }

    /// Statuses that mean "macOS refused", as opposed to "not there". A refusal
    /// is what the user sees when they dismiss the access prompt or hit Deny.
    ///
    /// `errSecNotAvailable` and `errSecDecode` are not refusals by the user, but
    /// they are equally "we were blocked from reading a credential that may
    /// exist" — and the alternative bucket claims the item is absent, which is
    /// the more damaging thing to get wrong.
    private static func isDenial(_ status: OSStatus) -> Bool {
        switch status {
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed,
             errSecInteractionRequired, errSecNotAvailable, errSecDecode:
            return true
        default:
            return false
        }
    }

    // MARK: - Payload parsing

    /// What one payload turned out to hold. `expired` is separated from
    /// `unusable` so a lapsed-but-otherwise-valid entry can be reported as such.
    enum PayloadVerdict: Equatable {
        case usable(ImportedToken)
        case expired(Date)
        case unusable
    }

    static func inspect(payload: String, now: Date) -> PayloadVerdict {
        // Bare token string — no envelope, so no deadline to report.
        if payload.hasPrefix("sk-ant-") {
            return validated(payload).map { .usable(ImportedToken(token: $0, expiresAt: nil)) } ?? .unusable
        }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unusable
        }
        // Current envelope: {"claudeAiOauth": {accessToken, expiresAt, …}, "mcpOAuth": {…}}.
        // An entry carrying only `mcpOAuth` falls through the legacy lookup and is unusable.
        if let oauth = obj["claudeAiOauth"] as? [String: Any] {
            return verdict(in: oauth, now: now)
        }
        return verdict(in: obj, now: now) // legacy flat envelope
    }

    private static func verdict(in obj: [String: Any], now: Date) -> PayloadVerdict {
        let expiry = expiryDate(obj["expiresAt"])
        for key in ["accessToken", "access_token", "oauth_token", "token"] {
            guard let v = obj[key] as? String else { continue }
            guard let token = validated(v) else { return .unusable }
            // Shape-checked first: a lapsed API key is still "no claude.ai
            // token", not "your token expired".
            if let expiry, expiry <= now { return .expired(expiry) }
            return .usable(ImportedToken(token: token, expiresAt: expiry))
        }
        return .unusable
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
