import XCTest
@testable import CCUsageStats

/// What the app logs when the token endpoint refuses a request. It is logged
/// `.public`, so it must carry the status and the error code and nothing else.
final class OAuthTokenFailureSummaryTests: XCTestCase {
    private func summary(_ status: Int, _ body: String) -> String {
        OAuthFlow.failureSummary(status: status, body: Data(body.utf8))
    }

    func testRFC6749ErrorCode() {
        XCTAssertEqual(summary(400, #"{"error":"invalid_grant","error_description":"Refresh token not found"}"#),
                       "400 invalid_grant")
    }

    func testAnthropicErrorObject() {
        XCTAssertEqual(summary(429, #"{"error":{"type":"rate_limit_error","message":"Rate limited."}}"#),
                       "429 rate_limit_error")
    }

    func testTypeBesideErrorObject() {
        XCTAssertEqual(summary(403, #"{"type":"error","error":{"message":"no"}}"#), "403")
    }

    func testUnreadableBodyLeavesTheStatus() {
        XCTAssertEqual(summary(502, "<html>Bad gateway</html>"), "502")
        XCTAssertEqual(summary(400, ""), "400")
        XCTAssertEqual(summary(400, #"{"error":17}"#), "400")
    }

    /// The description is free text from the server and may quote the request.
    func testDescriptionIsNeverIncluded() {
        let s = summary(400, #"{"error":"invalid_grant","error_description":"token sk-ant-ort01-SECRET is revoked"}"#)
        XCTAssertFalse(s.contains("SECRET"))
        XCTAssertFalse(s.contains("revoked"))
    }

    /// A code is an identifier. Anything else in that field is not echoed.
    func testCodeIsReducedToIdentifierCharacters() {
        XCTAssertEqual(summary(400, #"{"error":"invalid grant: sk-ant-ort01-SECRET"}"#), "400")
        XCTAssertEqual(summary(400, "{\"error\":\"\(String(repeating: "a", count: 65))\"}"), "400")
        // A bare token has hyphens; an error code does not.
        XCTAssertEqual(summary(400, #"{"error":"sk-ant-ort01-SECRET"}"#), "400")
        XCTAssertEqual(summary(400, #"{"error":"Invalid_Grant2"}"#), "400 Invalid_Grant2")
    }
}
