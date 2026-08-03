import CryptoKit
import Foundation

/// RFC 7636 PKCE, S256 method.
enum PKCE {
    /// 32 random bytes base64url-encodes to 43 characters, the RFC minimum.
    static func makeVerifier(byteCount: Int = 32) -> String {
        base64URL(randomData(byteCount))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String {
        base64URL(randomData(16))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}
