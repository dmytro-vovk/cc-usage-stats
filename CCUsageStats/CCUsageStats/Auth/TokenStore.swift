import Foundation
import Security

/// The app's own token plus the deadline it was imported with.
///
/// `expiresAt` doubles as provenance: only the Claude Code Keychain import path
/// knows a deadline, so a non-nil value means "imported from the CLI's Keychain,
/// short-lived" and nil means "pasted by hand, assumed long-lived".
struct StoredToken: Equatable {
    let token: String
    let expiresAt: Date?
}

enum TokenStore {
    /// The item the app stores the user's token in.
    static let liveServiceName = "cc-usage-stats"
    /// Scratch item the test suite gets instead, one per test worker process.
    static let testServicePrefix = "cc-usage-stats.tests"
    static var testServiceName: String { "\(testServicePrefix).\(TestEnvironment.scratchSuffix)" }

    /// Resolved from the process, not passed in by callers.
    ///
    /// `TokenStoreTests` exercises the real Keychain API — that is the point of
    /// those tests — and with a single fixed service name its `setUp`/`tearDown`
    /// `delete()` calls wiped the user's live token: running the suite signed
    /// the app out. Deciding here means a test cannot reach the live item even
    /// if it never opts in, which is the only version of this that stays true
    /// as tests are added.
    static var serviceName: String {
        TestEnvironment.isRunningTests ? testServiceName : liveServiceName
    }

    static let account = "oauth-token"

    enum TokenStoreError: Error { case unexpectedStatus(OSStatus) }

    static func read() -> String? { readStored()?.token }

    static func readStored() -> StoredToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return decode(data)
    }

    // MARK: - Envelope

    /// Serialized as `{"expiresAt": <epoch seconds>, "token": "sk-ant-oat01-…"}`.
    /// Builds before the envelope existed stored the bare token string, which
    /// `decode` still accepts.
    static func encode(token: String, expiresAt: Date?) -> Data {
        var obj: [String: Any] = ["token": token]
        if let expiresAt { obj["expiresAt"] = expiresAt.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return Data(token.utf8) // unreachable for String/Double values; degrade to legacy form
        }
        return data
    }

    static func decode(_ data: Data) -> StoredToken? {
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return nil }
        // Legacy item written by earlier builds: the bare token, no envelope.
        if raw.hasPrefix("sk-ant-") { return StoredToken(token: raw, expiresAt: nil) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (obj["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return StoredToken(token: token, expiresAt: expiresAt)
    }

    // MARK: - Keychain writes

    static func write(_ token: String, expiresAt: Date? = nil) throws {
        let data = encode(token: token, expiresAt: expiresAt)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Try update first.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TokenStoreError.unexpectedStatus(updateStatus)
        }

        // Add new.
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(addStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }
}
