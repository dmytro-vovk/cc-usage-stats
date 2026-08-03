import XCTest
@testable import CCUsageStats

/// Proves the two invariants `OAuthTokenProvider` exists to establish, using
/// a stubbed `URLSession` injected through `OAuthTokenProvider.init`:
///
///   1. The three-way classification of a refresh outcome is not
///      accidental — a transient failure (5xx / transport) must map to
///      `.temporarilyUnavailable`, and a hard 4xx rejection must map to
///      `.unusable`. Before this test existed the two return statements in
///      `OAuthUsageClient` could be swapped and the suite would stay green.
///   2. Single-flight: two concurrent `accessToken()` calls on an expiring
///      session must trigger exactly one network refresh, or the second
///      rotation would invalidate the first and sign the user out.
final class OAuthTokenProviderTests: XCTestCase {
    /// Stubs every request made through a `URLSession` configured with it.
    /// Records how many requests were started so the single-flight test can
    /// assert on it directly, and sleeps briefly before responding so a
    /// concurrent second call has time to observe `inFlight` before the
    /// first request completes.
    final class StubURLProtocol: URLProtocol {
        static var requestCount = 0
        static var handler: ((URLRequest) -> (status: Int, body: Data))?
        static var responseDelay: TimeInterval = 0
        private static let lock = NSLock()

        static func reset() {
            lock.lock()
            requestCount = 0
            handler = nil
            responseDelay = 0
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            StubURLProtocol.lock.lock()
            StubURLProtocol.requestCount += 1
            let delay = StubURLProtocol.responseDelay
            let handler = StubURLProtocol.handler
            StubURLProtocol.lock.unlock()

            if delay > 0 { Thread.sleep(forTimeInterval: delay) }

            guard let handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, body) = handler(request)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A session close enough to expiry that `accessToken()` always refreshes.
    private func expiringSession() -> OAuthSession {
        OAuthSession(accessToken: "stale", refreshToken: "refresh-me", expiresAt: 0, scopes: ["user:profile"])
    }

    private func tokenResponseBody(accessToken: String = "fresh") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "refresh_token": "fresh-refresh",
            "expires_in": 3600,
            "scope": "user:profile",
        ])
    }

    override func setUp() {
        StubURLProtocol.reset()
        try? OAuthSessionStore.delete()
    }
    override func tearDown() {
        StubURLProtocol.reset()
        try? OAuthSessionStore.delete()
    }

    // MARK: - (a) transient refresh failure

    func testTransientRefreshFailureYieldsTemporarilyUnavailableNotUnusable() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let provider = OAuthTokenProvider(session: expiringSession(), urlSession: stubbedSession())

        let result = await provider.accessToken(now: 0)

        switch result {
        case .temporarilyUnavailable:
            break // expected
        case .unusable:
            XCTFail("a 503 must not be classified as .unusable — that would tell an offline user to reconnect")
        case .token:
            XCTFail("expected a failure classification, got .token")
        }
    }

    func testTransportErrorYieldsTemporarilyUnavailable() async {
        // No handler registered at all → didFailWithError is invoked, giving
        // a transport-level failure rather than an HTTP status.
        let provider = OAuthTokenProvider(session: expiringSession(), urlSession: stubbedSession())

        let result = await provider.accessToken(now: 0)

        guard case .temporarilyUnavailable = result else {
            return XCTFail("expected .temporarilyUnavailable for a transport error, got \(result)")
        }
    }

    // MARK: - (b) 4xx refresh rejection

    func testFourXXRefreshRejectionYieldsUnusable() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        let provider = OAuthTokenProvider(session: expiringSession(), urlSession: stubbedSession())

        let result = await provider.accessToken(now: 0)

        guard case .unusable = result else {
            return XCTFail("expected .unusable for a 401 refresh rejection, got \(result)")
        }
    }

    // MARK: - (c) single-flight

    func testConcurrentAccessTokenCallsTriggerExactlyOneRefresh() async {
        StubURLProtocol.responseDelay = 0.05
        let body = tokenResponseBody()
        StubURLProtocol.handler = { _ in (200, body) }
        let provider = OAuthTokenProvider(session: expiringSession(), urlSession: stubbedSession())

        async let first = provider.accessToken(now: 0)
        async let second = provider.accessToken(now: 0)
        let (r1, r2) = await (first, second)

        for result in [r1, r2] {
            guard case .token(let token) = result else {
                XCTFail("expected both concurrent calls to resolve to a token, got \(result)")
                continue
            }
            XCTAssertEqual(token, "fresh")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1,
                       "two concurrent refreshes on an expiring session must share one network request")
    }
}
