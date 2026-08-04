import Foundation
import Security

/// A scoped OAuth session for `GET /api/oauth/usage`.
///
/// Stored separately from the legacy pasted token (`TokenStore`, account
/// `oauth-token`), which is deliberately left intact so the response-header
/// fallback keeps working for users who never authorize.
struct OAuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry, epoch seconds.
    let expiresAt: Int64
    let scopes: [String]

    var hasProfileScope: Bool { scopes.contains("user:profile") }

    func isExpiring(now: Int64, leeway: Int64 = 300) -> Bool {
        expiresAt - now < leeway
    }

    /// Decodes an *initial* token grant — the authorization-code exchange.
    /// Returns nil when the body is not a usable first grant.
    ///
    /// `requestedScopes` is what the authorize request asked for, and is not
    /// a guess: RFC 6749 §5.1 makes `scope` OPTIONAL in the response *only*
    /// when the granted scope is identical to the requested scope, and
    /// REQUIRES the server to state `scope` whenever it grants anything
    /// narrower. So an omitted `scope` means exactly "you got what you asked
    /// for", and substituting the requested set is the specified reading —
    /// not an assumption. Substituting an empty set instead (the original
    /// behaviour) silently produced a session whose `hasProfileScope` was
    /// false, which the poller then refused to use, forever, with no error.
    ///
    /// Still strict about the two fields no reading can supply: a first grant
    /// with no `access_token` is not a grant, and one with no `refresh_token`
    /// is unusable past the first hour. The refresh case is the opposite in
    /// every respect — see `fromRefreshResponse`.
    static func fromTokenResponse(
        _ data: Data,
        now: Int64,
        requestedScopes: [String]
    ) -> OAuthSession? {
        guard let fields = TokenResponseFields(data),
              let access = fields.accessToken,
              let refresh = fields.refreshToken else {
            return nil
        }
        return OAuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now + fields.expiresIn,
            scopes: fields.scopes ?? requestedScopes
        )
    }

    /// Decodes a *refresh* response, carrying forward from `previous`
    /// everything the server is allowed to leave out.
    ///
    /// RFC 6749 §5.1 makes `scope` OPTIONAL when the granted scope matches
    /// what was requested, and §6 makes `refresh_token` OPTIONAL in a refresh
    /// response — a server that does not rotate simply omits it. Reading
    /// either absence the way an initial grant would corrupts a perfectly
    /// valid session:
    ///   - an empty `scopes` is persisted to the Keychain, and the next
    ///     launch decides the grant lacks `user:profile` and abandons the
    ///     OAuth path — silently, and permanently until the user reconnects;
    ///   - a missing `refresh_token` fails the parse, surfaces as
    ///     `.malformedTokenResponse`, and is then classified transient — a
    ///     non-rotating server would put the app in a permanent retry loop.
    ///
    /// A refresh response that omits `access_token` is still malformed and
    /// still returns nil: that field is the entire point of the exchange.
    static func fromRefreshResponse(
        _ data: Data,
        now: Int64,
        previous: OAuthSession
    ) -> OAuthSession? {
        guard let fields = TokenResponseFields(data),
              let access = fields.accessToken else {
            return nil
        }
        return OAuthSession(
            accessToken: access,
            refreshToken: fields.refreshToken ?? previous.refreshToken,
            expiresAt: now + fields.expiresIn,
            scopes: fields.scopes ?? previous.scopes
        )
    }

    /// The raw fields of a token-endpoint response, each left optional so the
    /// two decoders above — and only they — decide what an absent field means.
    private struct TokenResponseFields {
        let accessToken: String?
        let refreshToken: String?
        /// nil means "the response carried no `scope` member at all", which
        /// is different from an explicitly empty scope list.
        let scopes: [String]?
        let expiresIn: Int64

        init?(_ data: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            accessToken = obj["access_token"] as? String
            refreshToken = obj["refresh_token"] as? String
            if let s = obj["scope"] as? String {
                scopes = s.split(separator: " ").map(String.init)
            } else if let a = obj["scope"] as? [String] {
                scopes = a
            } else {
                scopes = nil
            }
            expiresIn = Int64((obj["expires_in"] as? Double) ?? 3600)
        }
    }
}

enum OAuthSessionStore {
    static let account = "oauth-session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TokenStore.serviceName,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> OAuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthSession.self, from: data)
    }

    static func write(_ session: OAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TokenStore.TokenStoreError.unexpectedStatus(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStore.TokenStoreError.unexpectedStatus(addStatus)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw TokenStore.TokenStoreError.unexpectedStatus(status)
        }
    }
}
