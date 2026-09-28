import XCTest
@testable import CCUsageStats

final class PKCETests: XCTestCase {
    /// RFC 7636 Appendix B test vector.
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsBase64URLAndWithinRFCLengthBounds() {
        let v = PKCE.makeVerifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertNil(v.rangeOfCharacter(from: allowed.inverted),
                     "verifier must contain only unreserved characters")
    }

    func testVerifiersAreDistinct() {
        XCTAssertNotEqual(PKCE.makeVerifier(), PKCE.makeVerifier())
    }

    func testStateIsNonEmptyAndDistinct() {
        let a = PKCE.randomState()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, PKCE.randomState())
    }

    /// Claude Code's `state` is 32 random bytes as base64url (43 chars).
    /// A 16-byte (22-char) state got "Authorization failed — Invalid
    /// request format" from the authorize page for every scope tried.
    func testStateMatchesClaudeCodeLength() {
        let s = PKCE.randomState()
        XCTAssertEqual(s.count, 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertNil(s.rangeOfCharacter(from: allowed.inverted))
    }
}
