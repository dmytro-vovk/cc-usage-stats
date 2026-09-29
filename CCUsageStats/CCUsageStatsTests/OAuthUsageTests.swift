import XCTest
@testable import CCUsageStats

final class OAuthUsageTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testUtilizationIsPercentAndNotRescaled() throws {
        let json = """
        {"five_hour":{"utilization":42.5,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 42.5, accuracy: 0.001)
    }

    func testISO8601WithAndWithoutFractionalSeconds() {
        XCTAssertEqual(OAuthUsage.epochSeconds(fromISO8601: "2026-07-28T04:00:00Z"), 1785211200)
        XCTAssertEqual(OAuthUsage.epochSeconds(fromISO8601: "2026-07-28T04:00:00.123Z"), 1785211200)
        XCTAssertNil(OAuthUsage.epochSeconds(fromISO8601: "not a date"))
    }

    func testUnknownModelKeysAreSurfaced() throws {
        let json = """
        {"seven_day_fable":{"utilization":93,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_brandnew":{"utilization":12,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(Set(snap.models.keys), ["seven_day_fable", "seven_day_brandnew"])
        XCTAssertEqual(snap.models["seven_day_fable"]!.usedPercentage, 93, accuracy: 0.001)
    }

    func testDenylistedKeysAreDropped() throws {
        let json = """
        {"seven_day":{"utilization":18,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_oauth_apps":{"utilization":5,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(snap.models.isEmpty)
        XCTAssertEqual(snap.sevenDay!.usedPercentage, 18, accuracy: 0.001)
    }

    func testNullUtilizationIsSkipped() throws {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_fable":{"utilization":null,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(snap.models.isEmpty)
    }

    func testIntegerUtilizationParses() throws {
        let json = """
        {"five_hour":{"utilization":0,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 0, accuracy: 0.001)
    }

    func testFieldlessBodyYieldsNotSubscriber() {
        let result = OAuthUsage.parse(status: 200, body: body("{}"))
        if case .notSubscriber = result { return }
        XCTFail("expected .notSubscriber, got \(result)")
    }

    func test403ScopeErrorYieldsInsufficientScope() {
        let json = """
        {"type":"error","error":{"type":"permission_error",
         "message":"OAuth token does not meet scope requirement user:profile"}}
        """
        let result = OAuthUsage.parse(status: 403, body: body(json))
        if case .insufficientScope = result { return }
        XCTFail("expected .insufficientScope, got \(result)")
    }

    func test403WithoutScopeMessageYieldsInvalidToken() {
        let result = OAuthUsage.parse(status: 403, body: body(#"{"error":"forbidden"}"#))
        if case .invalidToken = result { return }
        XCTFail("expected .invalidToken, got \(result)")
    }

    func test401YieldsInvalidToken() {
        let result = OAuthUsage.parse(status: 401, body: Data())
        if case .invalidToken = result { return }
        XCTFail()
    }

    func test429YieldsRateLimited() {
        let result = OAuthUsage.parse(status: 429, body: Data())
        if case .rateLimited = result { return }
        XCTFail()
    }

    func test5xxYieldsTransient() {
        let result = OAuthUsage.parse(status: 503, body: Data())
        if case .transient = result { return }
        XCTFail()
    }

    /// Diagnostic summary of what the endpoint actually returned: every
    /// top-level key, sorted, tagged with whether it is a usable window,
    /// null, or some other shape — so an account's real key set can be read
    /// from the system log without exposing the body.
    func testWindowSummaryTagsEveryKey() {
        let json = """
        {"seven_day":{"utilization":24,"resets_at":"2026-07-28T04:00:00Z"},
         "five_hour":{"utilization":7.5,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_sonnet":null,
         "cinder_cove":{"utilization":null,"resets_at":null},
         "extra_usage":{"is_enabled":false},
         "odd":3}
        """
        XCTAssertEqual(
            OAuthUsage.windowSummary(body(json)),
            "cinder_cove=object[resets_at,utilization] extra_usage=object[is_enabled] "
            + "five_hour=7.5% odd=number seven_day=24% seven_day_sonnet=null"
        )
        XCTAssertEqual(OAuthUsage.windowSummary(body("not json")), "unparseable body")
    }

    /// One level deeper for the structures that may carry per-model usage
    /// (`seven_day_breakdown`, `limits`, `nimbus_quill`): compact, key-sorted
    /// JSON of just those subtrees, so their shape can be read from the log.
    func testDetailSummaryDumpsOnlyTheNamedSubtrees() {
        let json = """
        {"five_hour":{"utilization":9,"resets_at":"2026-07-28T04:00:00Z"},
         "limits":[{"name":"Fable","utilization":40}],
         "seven_day_breakdown":{"rows":[{"model":"fable","pct":12.5}]},
         "secretish":"x"}
        """
        XCTAssertEqual(
            OAuthUsage.detailSummary(body(json), keys: ["seven_day_breakdown", "limits", "nimbus_quill"]),
            #"limits=[{"name":"Fable","utilization":40}] seven_day_breakdown={"rows":[{"model":"fable","pct":12.5}]}"#
        )
    }
}
