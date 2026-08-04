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

    // MARK: - Initial grant (authorization-code exchange)

    private let requested = ["user:profile"]

    private func initialGrant(_ json: String, now: Int64 = 0) -> OAuthSession? {
        OAuthSession.fromTokenResponse(Data(json.utf8), now: now, requestedScopes: requested)
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "scope":"user:profile","token_type":"Bearer"}
        """
        let session = try XCTUnwrap(initialGrant(json, now: 1_000))
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
        let session = try XCTUnwrap(initialGrant(json))
        XCTAssertEqual(session.scopes, ["user:profile", "user:inference"])
    }

    func testTokenResponseMissingAccessTokenReturnsNil() {
        let json = #"{"refresh_token":"rt","expires_in":60}"#
        XCTAssertNil(initialGrant(json))
    }

    /// A first grant with no `refresh_token` is unusable past the first hour,
    /// and nothing can supply one — unlike a *refresh* response, where the
    /// previous session still holds a valid one.
    func testTokenResponseMissingRefreshTokenReturnsNil() {
        let json = #"{"access_token":"at","expires_in":60,"scope":"user:profile"}"#
        XCTAssertNil(initialGrant(json))
    }

    /// RFC 6749 §5.1: `scope` is OPTIONAL in the response only when the
    /// granted scope is identical to the requested scope, and REQUIRED
    /// whenever anything narrower was granted. So an omitted `scope` means
    /// "exactly what you asked for", and reading it as the empty set — which
    /// this used to do — produced a session whose `hasProfileScope` was
    /// false. The poller then refused to use it and nothing ever said why.
    func testTokenResponseOmittingScopeMeansTheRequestedScope() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":60}"#
        let session = try XCTUnwrap(initialGrant(json))
        XCTAssertEqual(session.scopes, requested)
        XCTAssertTrue(session.hasProfileScope,
                      "an omitted scope must not silently disable the OAuth path")
    }

    /// The other half of the same RFC rule: a server that grants *less* must
    /// say so, and when it does we must believe it rather than the request.
    func testTokenResponseNarrowerGrantedScopeWins() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":60,
         "scope":"user:inference"}
        """
        let session = try XCTUnwrap(initialGrant(json))
        XCTAssertEqual(session.scopes, ["user:inference"])
        XCTAssertFalse(session.hasProfileScope)
    }

    func testTokenResponseDefaultsExpiryToOneHour() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","scope":"user:profile"}"#
        let session = try XCTUnwrap(initialGrant(json, now: 100))
        XCTAssertEqual(session.expiresAt, 3_700)
    }

    // MARK: - Refresh response
    //
    // The mirror image of the initial grant: RFC 6749 §5.1 lets a refresh
    // response omit `scope`, and §6 lets it omit `refresh_token` (a server
    // that does not rotate simply leaves it out). Reading either absence the
    // way an initial grant would corrupts a perfectly valid session — an
    // empty `scopes` gets persisted and the next launch decides the grant
    // lacks `user:profile`, and a failed parse surfaces as
    // `.malformedTokenResponse`, which is classified transient and retries
    // forever.

    private func refresh(_ json: String, now: Int64 = 0) -> OAuthSession? {
        OAuthSession.fromRefreshResponse(Data(json.utf8), now: now, previous: sample)
    }

    func testRefreshResponseWithEveryFieldReplacesEverything() throws {
        let json = """
        {"access_token":"at2","refresh_token":"rt2","expires_in":60,
         "scope":"user:profile user:inference"}
        """
        let session = try XCTUnwrap(refresh(json, now: 10))
        XCTAssertEqual(session.accessToken, "at2")
        XCTAssertEqual(session.refreshToken, "rt2")
        XCTAssertEqual(session.expiresAt, 70)
        XCTAssertEqual(session.scopes, ["user:profile", "user:inference"])
    }

    func testRefreshResponseOmittingScopeKeepsThePreviousScopes() throws {
        let json = #"{"access_token":"at2","refresh_token":"rt2","expires_in":60}"#
        let session = try XCTUnwrap(refresh(json))
        XCTAssertEqual(session.scopes, sample.scopes)
        XCTAssertTrue(session.hasProfileScope,
                      "an omitted scope must not silently demote a working session")
    }

    /// A non-rotating server. The previous refresh token stays valid and must
    /// be carried forward; failing the parse instead would loop forever.
    func testRefreshResponseOmittingRefreshTokenKeepsThePreviousOne() throws {
        let json = #"{"access_token":"at2","expires_in":60,"scope":"user:profile"}"#
        let session = try XCTUnwrap(refresh(json))
        XCTAssertEqual(session.refreshToken, sample.refreshToken)
        XCTAssertEqual(session.accessToken, "at2")
    }

    /// The minimal legal refresh response: a new access token and nothing
    /// else. Everything the server left out comes from the previous session.
    func testRefreshResponseOmittingBothCarriesBothForward() throws {
        let json = #"{"access_token":"at2","expires_in":60}"#
        let session = try XCTUnwrap(refresh(json))
        XCTAssertEqual(session.refreshToken, sample.refreshToken)
        XCTAssertEqual(session.scopes, sample.scopes)
        XCTAssertEqual(session.accessToken, "at2")
    }

    /// The one field no leniency can cover: it is the entire point of the
    /// exchange, and `previous`'s copy is the stale one being replaced.
    func testRefreshResponseMissingAccessTokenStillReturnsNil() {
        XCTAssertNil(refresh(#"{"refresh_token":"rt2","expires_in":60}"#))
        XCTAssertNil(refresh(#"{}"#))
        XCTAssertNil(refresh("not json at all"))
    }

    func testRefreshResponseDefaultsExpiryToOneHour() throws {
        let session = try XCTUnwrap(refresh(#"{"access_token":"at2"}"#, now: 100))
        XCTAssertEqual(session.expiresAt, 3_700)
    }
}
