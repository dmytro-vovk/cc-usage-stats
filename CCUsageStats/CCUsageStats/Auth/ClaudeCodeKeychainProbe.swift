import Foundation
import Security

/// One-shot best-effort read of the existing Claude Code OAuth token from
/// macOS Keychain. Returns nil if absent, denied, or the value is not a
/// recognizable OAuth token. macOS surfaces a system access prompt the
/// first time another process queries that entry.
enum ClaudeCodeKeychainProbe {
    private static let service = "Claude Code-credentials"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Claude Code may store either the bare token string or a JSON envelope.
        let candidate = extractToken(from: raw)
        guard let token = candidate, token.hasPrefix("sk-ant-oat01-") else {
            return nil
        }
        return token
    }

    private static func extractToken(from raw: String) -> String? {
        // Bare token? Return as-is.
        if raw.hasPrefix("sk-ant-") { return raw }

        // JSON object? Look for common keys.
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["accessToken", "access_token", "oauth_token", "token"] {
            if let v = obj[key] as? String { return v }
        }
        return nil
    }
}
