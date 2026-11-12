import XCTest
@testable import CCUsageStats

final class AnthropicAPITests: XCTestCase {
    private let okBody = Data(#"{"id":"msg_x","type":"message","role":"assistant","content":[{"type":"text","text":""}],"model":"claude-haiku-4-5","stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":1}}"#.utf8)

    private let validHeaders: [String: String] = [
        "anthropic-ratelimit-unified-5h-utilization": "0.42",
        "anthropic-ratelimit-unified-5h-reset": "1714075200",
        "anthropic-ratelimit-unified-7d-utilization": "0.18",
        "anthropic-ratelimit-unified-7d-reset": "1714665600",
    ]

    func testParseHeadersConvertsFractionToPercent() throws {
        let result = AnthropicAPI.parse(status: 200, headers: validHeaders, body: okBody)
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 42.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHour!.resetsAt, 1714075200)
        XCTAssertEqual(snap.sevenDay!.usedPercentage, 18.0, accuracy: 0.001)
        XCTAssertEqual(snap.sevenDay!.resetsAt, 1714665600)
    }

    func testHeaderKeyLookupIsCaseInsensitive() throws {
        let mixedCase: [String: String] = [
            "Anthropic-RateLimit-Unified-5h-Utilization": "0.5",
            "ANTHROPIC-RATELIMIT-UNIFIED-5H-RESET": "100",
        ]
        let result = AnthropicAPI.parse(status: 200, headers: mixedCase, body: okBody)
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 50.0, accuracy: 0.001)
        XCTAssertNil(snap.sevenDay)
    }

    func testFiveHourOnly() throws {
        let headers: [String: String] = [
            "anthropic-ratelimit-unified-5h-utilization": "0.1",
            "anthropic-ratelimit-unified-5h-reset": "200",
        ]
        let result = AnthropicAPI.parse(status: 200, headers: headers, body: okBody)
        guard case let .success(snap) = result else { return XCTFail() }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 10.0, accuracy: 0.001)
        XCTAssertNil(snap.sevenDay)
    }

    func testSevenDayWithoutFiveHourMarksFiveHourAbsent() throws {
        let headers = [
            "anthropic-ratelimit-unified-7d-utilization": "0.86",
            "anthropic-ratelimit-unified-7d-reset": "1714665600",
        ]
        let result = AnthropicAPI.parse(status: 200, headers: headers, body: okBody)
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertNil(snap.fiveHour)
        XCTAssertTrue(snap.fiveHourIsAbsent)
    }

    func testMalformedFiveHourHeaderIsNotAbsence() throws {
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.4",
            "anthropic-ratelimit-unified-7d-utilization": "0.86",
            "anthropic-ratelimit-unified-7d-reset": "1714665600",
        ]
        let result = AnthropicAPI.parse(status: 200, headers: headers, body: okBody)
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertNil(snap.fiveHour)
        XCTAssertFalse(snap.fiveHourIsAbsent)
    }

    func testNoRateLimitHeadersYieldsNotSubscriber() {
        let result = AnthropicAPI.parse(status: 200, headers: [:], body: okBody)
        if case .notSubscriber = result { return }
        XCTFail("expected .notSubscriber, got \(result)")
    }

    func test401YieldsInvalidToken() {
        let result = AnthropicAPI.parse(status: 401, headers: [:], body: Data())
        if case .invalidToken = result { return }
        XCTFail()
    }

    func test403YieldsInvalidToken() {
        let api = Data(#"{"type":"error","error":{"type":"permission_error","message":"x"}}"#.utf8)
        guard case .invalidToken = AnthropicAPI.parse(status: 403, headers: [:], body: api) else { return XCTFail() }
        // A 403 from a WAF or proxy in front of the API is not a verdict.
        for raw in ["", "<html>blocked</html>", #"{"message":"blocked"}"#] {
            guard case .transient = AnthropicAPI.parse(status: 403, headers: [:], body: Data(raw.utf8)) else {
                return XCTFail(raw)
            }
        }
    }

    func test429YieldsRateLimited() {
        let result = AnthropicAPI.parse(status: 429, headers: [:], body: Data())
        if case .rateLimited = result { return }
        XCTFail()
    }

    func test5xxYieldsTransient() {
        let result = AnthropicAPI.parse(status: 503, headers: [:], body: Data())
        if case .transient = result { return }
        XCTFail()
    }

    /// `Double("nan")` and `Double("inf")` parse. A non-finite utilization is
    /// a malformed header, not a reading: downstream `Int(x.rounded())` traps.
    func testNonFiniteUtilizationIsNotAWindow() {
        for bad in ["nan", "inf", "-inf", "NaN", "infinity"] {
            var headers = validHeaders
            headers["anthropic-ratelimit-unified-5h-utilization"] = bad
            guard case let .success(snap) = AnthropicAPI.parse(status: 200, headers: headers, body: okBody) else {
                XCTFail("the 7d window alone is still a reading (\(bad))"); continue
            }
            XCTAssertNil(snap.fiveHour, bad)
            XCTAssertNotNil(snap.sevenDay, bad)
        }
    }
}
