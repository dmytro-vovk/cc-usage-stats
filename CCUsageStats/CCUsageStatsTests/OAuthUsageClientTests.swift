import XCTest
@testable import CCUsageStats

/// `OAuthUsageClient` had no tests at all, and its entire job is a
/// three-way translation:
///
///   `.token`                  → issue the GET, return whatever it parses to
///   `.unusable`               → `.insufficientScope`
///   `.temporarilyUnavailable` → `.transient`
///
/// Swapping the last two compiles, ships, and leaves every other test green
/// — and it is the difference between telling a user on dropped Wi-Fi
/// "you're offline, last value shown" and "your account connection expired,
/// reconnect". Since the fix for a permanently refused primary now *stops
/// polling and evicts the Keychain session*, that swap would also throw away
/// a working connection every time a coffee-shop network hiccuped.
///
/// Reuses `OAuthTokenProviderTests.StubURLProtocol`, whose request counter is
/// what proves the two refusal paths never touch the network at all.
final class OAuthUsageClientTests: XCTestCase {
    private typealias Stub = OAuthTokenProviderTests.StubURLProtocol

    override func setUp() {
        Stub.reset()
        try? OAuthSessionStore.delete()
    }
    override func tearDown() {
        Stub.reset()
        try? OAuthSessionStore.delete()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    /// Far enough from expiry that `accessToken()` hands the token straight
    /// back without refreshing — so the only request made is the usage GET.
    private func liveSession() -> OAuthSession {
        OAuthSession(
            accessToken: "live-access-token",
            refreshToken: "rt",
            expiresAt: 4_000_000_000,
            scopes: ["user:profile"]
        )
    }

    /// Expiring, so `accessToken()` must refresh — and the stub decides how
    /// that refresh goes.
    private func expiringSession() -> OAuthSession {
        OAuthSession(accessToken: "stale", refreshToken: "rt", expiresAt: 0, scopes: ["user:profile"])
    }

    private func client(session: OAuthSession?) -> OAuthUsageClient {
        let urlSession = stubbedSession()
        return OAuthUsageClient(
            provider: OAuthTokenProvider(session: session, urlSession: urlSession),
            session: urlSession
        )
    }

    // MARK: - .token → a real request

    func testUsableTokenIssuesAnAuthorizedGetToTheUsageEndpoint() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 42.0, "resets_at": "2026-08-04T12:00:00Z"],
            "seven_day_opus": ["utilization": 83.0, "resets_at": "2026-08-09T12:00:00Z"],
        ])
        let captured = CapturedRequest()
        Stub.handler = { req in
            captured.request = req
            return (200, body)
        }

        let result = await client(session: liveSession()).fetchRateLimits()

        guard case .success(let snapshot) = result else {
            return XCTFail("expected .success, got \(result)")
        }
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 42)
        XCTAssertEqual(snapshot.models["seven_day_opus"]?.usedPercentage, 83)
        XCTAssertTrue(snapshot.modelsAreAuthoritative,
                      "this is the only source that can see model windows")

        let req = try XCTUnwrap(captured.request)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer live-access-token")
    }

    /// Unlike the header path — a POST, which URLSession never serves from
    /// cache — this is a cacheable GET. A replayed 200 would hand back an
    /// unchanging utilization that the poller stamps with a fresh
    /// `captured_at`, i.e. a frozen number presented as a live reading.
    func testUsageRequestNeverReadsFromTheCache() async throws {
        let captured = CapturedRequest()
        Stub.handler = { req in
            captured.request = req
            return (200, Data("{}".utf8))
        }

        _ = await client(session: liveSession()).fetchRateLimits()

        let req = try XCTUnwrap(captured.request)
        XCTAssertEqual(req.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testNonSuccessStatusIsClassifiedByOAuthUsageParse() async {
        Stub.handler = { _ in (429, Data()) }
        let result = await client(session: liveSession()).fetchRateLimits()
        XCTAssertEqual(result, .rateLimited)
    }

    // MARK: - .unusable → .insufficientScope

    /// No session stored at all. The poller reads `.insufficientScope` as
    /// "this credential will never work" and, with no fallback, retires it.
    func testNoSessionYieldsInsufficientScopeWithoutTouchingTheNetwork() async {
        let result = await client(session: nil).fetchRateLimits()

        XCTAssertEqual(result, .insufficientScope)
        XCTAssertEqual(Stub.requestCount, 0, "there is no token to make a request with")
    }

    /// A 4xx on refresh means the grant is gone for good — the same
    /// `.unusable` verdict, reached the hard way.
    func testPermanentlyRejectedRefreshYieldsInsufficientScope() async {
        Stub.handler = { _ in (401, Data()) }

        let result = await client(session: expiringSession()).fetchRateLimits()

        XCTAssertEqual(result, .insufficientScope,
                       "a dead grant must not be mistaken for a network blip")
        XCTAssertEqual(Stub.requestCount, 1, "the refresh only; no usage GET follows a dead grant")
    }

    // MARK: - .temporarilyUnavailable → .transient

    /// The assertion that matters most in this file. A 5xx while refreshing
    /// is a server hiccup, not a revoked grant: it must stay transient so the
    /// offline detector counts it and the UI says "offline", never
    /// "reconnect your account" — which now also evicts the Keychain session.
    func testServerErrorOnRefreshStaysTransient() async {
        Stub.handler = { _ in (503, Data()) }

        let result = await client(session: expiringSession()).fetchRateLimits()

        guard case .transient = result else {
            return XCTFail("expected .transient for a 5xx during refresh, got \(result)")
        }
    }

    /// Dropped Wi-Fi: no handler registered, so the stub fails the request at
    /// the transport level.
    func testTransportFailureOnRefreshStaysTransient() async {
        let result = await client(session: expiringSession()).fetchRateLimits()

        guard case .transient = result else {
            return XCTFail("expected .transient for a transport error, got \(result)")
        }
    }

    /// And a transport failure on the usage GET itself, with a token that
    /// never needed refreshing.
    func testTransportFailureOnTheUsageRequestIsTransient() async {
        let result = await client(session: liveSession()).fetchRateLimits()

        guard case .transient = result else {
            return XCTFail("expected .transient for a failed usage GET, got \(result)")
        }
    }

    /// Box for the request the stub saw, since the handler is a closure that
    /// cannot write to a local `var`.
    private final class CapturedRequest {
        var request: URLRequest?
    }
}
