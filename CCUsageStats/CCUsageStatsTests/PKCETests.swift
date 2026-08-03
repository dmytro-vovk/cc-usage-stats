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
}
