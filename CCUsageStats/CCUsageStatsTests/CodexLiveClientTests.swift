import XCTest
@testable import CCUsageStats

final class CodexLiveClientTests: XCTestCase {
    private func jwt(exp: Int64) -> String {
        let payload = Data(#"{"exp":\#(exp),"iat":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
    }

    func testReadsCredentialsFromAuthJSON() throws {
        let json = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"i","access_token":"\#(jwt(exp: 500))","refresh_token":"r","account_id":"acct-1"},"last_refresh":"2026-10-02T13:23:28Z"}"#
        let c = try XCTUnwrap(CodexCredentials.parse(Data(json.utf8)))
        XCTAssertEqual(c.accountID, "acct-1")
        XCTAssertEqual(c.expiresAt, 500)
        XCTAssertTrue(c.isExpired(now: 500))
        XCTAssertFalse(c.isExpired(now: 499))
    }

    func testMissingTokensIsNil() {
        XCTAssertNil(CodexCredentials.parse(Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#.utf8)))
        XCTAssertNil(CodexCredentials.parse(Data("garbage".utf8)))
    }

    func testOpaqueAccessTokenHasNoKnownExpiry() throws {
        let json = #"{"tokens":{"access_token":"opaque","account_id":"a"}}"#
        let c = try XCTUnwrap(CodexCredentials.parse(Data(json.utf8)))
        XCTAssertNil(c.expiresAt)
        XCTAssertFalse(c.isExpired(now: .max))
    }

    func testParsesUsageResponse() throws {
        let body = #"{"user_id":"u","plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_after_seconds":100,"reset_at":1791988070},"secondary_window":{"used_percent":40.5,"limit_window_seconds":18000,"reset_after_seconds":5,"reset_at":1791000000}},"additional_rate_limits":[{"limit_name":"x","rate_limit":{"primary_window":{"used_percent":99,"limit_window_seconds":604800,"reset_at":1}}}],"credits":{"balance":"0"}}"#
        let s = try XCTUnwrap(CodexLiveClient.parseUsage(Data(body.utf8), observedAt: 77))
        XCTAssertEqual(s.planType, "prolite")
        XCTAssertEqual(s.source, .live)
        XCTAssertEqual(s.observedAt, 77)
        XCTAssertEqual(s.windows, [
            CodexWindow(usedPercent: 40.5, windowMinutes: 300, resetsAt: 1791000000),
            CodexWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: 1791988070),
        ])
    }

    func testUsageResponseWithoutRateLimitIsNil() {
        XCTAssertNil(CodexLiveClient.parseUsage(Data(#"{"plan_type":"free","rate_limit":null}"#.utf8), observedAt: 0))
        XCTAssertNil(CodexLiveClient.parseUsage(Data("<html>".utf8), observedAt: 0))
    }

    func testRequestShape() throws {
        let c = CodexCredentials(accessToken: "tok", accountID: "acct", expiresAt: nil)
        let r = CodexLiveClient.request(for: c)
        XCTAssertEqual(r.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(r.value(forHTTPHeaderField: "chatgpt-account-id"), "acct")
    }

    func testFetchNeverSendsAnExpiredToken() async {
        let creds = CodexCredentials(accessToken: "t", accountID: "a", expiresAt: 10)
        let r = await CodexLiveClient.fetch(credentials: creds, now: 11) { _ in
            XCTFail("an expired token must not be sent")
            return (Data(), 200)
        }
        XCTAssertEqual(r, .failure(.expired))
    }

    func testFetchMapsStatusCodes() async {
        let creds = CodexCredentials(accessToken: "t", accountID: "a", expiresAt: nil)
        let unauthorized = await CodexLiveClient.fetch(credentials: creds, now: 0) { _ in (Data(), 401) }
        XCTAssertEqual(unauthorized, .failure(.expired))
        let server = await CodexLiveClient.fetch(credentials: creds, now: 0) { _ in (Data(), 503) }
        XCTAssertEqual(server, .failure(.http(503)))
        let ok = await CodexLiveClient.fetch(credentials: creds, now: 5) { _ in
            (Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_at":9}}}"#.utf8), 200)
        }
        guard case .success(let s) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(s.observedAt, 5)
        XCTAssertEqual(s.planType, "plus")
    }
}
