import XCTest
@testable import CCUsageStats

final class OAuthSessionTests: XCTestCase {
    private let sample = OAuthSession(
        accessToken: "at",
        refreshToken: "rt",
        expiresAt: 1_000_000,
        scopes: ["user:profile"]
    )

    func testHasProfileScope() {
        XCTAssertTrue(sample.hasProfileScope)
        let without = OAuthSession(accessToken: "a", refreshToken: "r",
                                   expiresAt: 0, scopes: ["user:inference"])
        XCTAssertFalse(without.hasProfileScope)
    }

    func testIsExpiringUsesLeeway() {
        // 400s left, 300s leeway → not yet expiring.
        XCTAssertFalse(sample.isExpiring(now: 999_600, leeway: 300))
        // 200s left → expiring.
        XCTAssertTrue(sample.isExpiring(now: 999_800, leeway: 300))
        // Already past.
        XCTAssertTrue(sample.isExpiring(now: 1_000_001, leeway: 300))
    }

    func testJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let back = try JSONDecoder().decode(OAuthSession.self, from: data)
        XCTAssertEqual(back, sample)
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "scope":"user:profile","token_type":"Bearer"}
        """
        let session = try XCTUnwrap(
            OAuthSession.fromTokenResponse(Data(json.utf8), now: 1_000)
        )
        XCTAssertEqual(session.accessToken, "at")
        XCTAssertEqual(session.refreshToken, "rt")
        XCTAssertEqual(session.expiresAt, 4_600)
        XCTAssertEqual(session.scopes, ["user:profile"])
    }

    func testTokenResponseAcceptsScopeArray() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":60,
         "scope":["user:profile","user:inference"]}
        """
        let session = try XCTUnwrap(
            OAuthSession.fromTokenResponse(Data(json.utf8), now: 0)
        )
        XCTAssertEqual(session.scopes, ["user:profile", "user:inference"])
    }

    func testTokenResponseMissingAccessTokenReturnsNil() {
        let json = #"{"refresh_token":"rt","expires_in":60}"#
        XCTAssertNil(OAuthSession.fromTokenResponse(Data(json.utf8), now: 0))
    }
}
