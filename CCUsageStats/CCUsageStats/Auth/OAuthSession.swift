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

    /// Decodes an OAuth token-endpoint response. Returns nil when the body
    /// is not a successful token grant.
    static func fromTokenResponse(_ data: Data, now: Int64) -> OAuthSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            return nil
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let scopes: [String]
        if let s = obj["scope"] as? String {
            scopes = s.split(separator: " ").map(String.init)
        } else if let a = obj["scope"] as? [String] {
            scopes = a
        } else {
            scopes = []
        }
        return OAuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now + Int64(expiresIn),
            scopes: scopes
        )
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
