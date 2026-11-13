import XCTest
@testable import CCUsageStats

final class GeminiUsageTests: XCTestCase {
    // Shape copied from a real `agy -p /usage --output-format json` (Antigravity CLI 1.5.8), trimmed.
    private func output(
        gemini: String = #"{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.801857590675354,"reset_time":"2026-11-20T17:25:18Z"}"#,
        thirdParty: String = #"{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-20T19:59:49Z"}"#
    ) -> String {
        #"{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t80%\t2026-11-20T17:25:18Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[\#(gemini)]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[\#(thirdParty)]}]}}}"#
    }

    private func parse(_ text: String) -> Result<GeminiSnapshot, GeminiReadError> {
        GeminiUsageParser.parse(output: text, observedAt: 1_000)
    }

    func testParsesBucketsPerGroupInOrder() throws {
        let s = try parse(output()).get()
        XCTAssertEqual(s.observedAt, 1_000)
        XCTAssertEqual(s.buckets.map(\.id), ["gemini-weekly", "3p-weekly"])
        XCTAssertEqual(s.buckets.map(\.group), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(s.buckets.map(\.windowMinutes), [10080, 10080])
        XCTAssertEqual(s.buckets[0].usedPercent, (1 - 0.801857590675354) * 100, accuracy: 1e-6)
        XCTAssertEqual(s.buckets[1].usedPercent, 0)
        XCTAssertEqual(s.buckets[0].resetsAt, 1_795_195_518) // 2026-11-20T17:25:18Z
        XCTAssertEqual(s.buckets[0].label, "Gemini Models weekly")
    }

    func testUsedPercentCarriesNoFloatNoise() throws {
        let s = try parse(output(
            gemini: #"{"id":"g","window":"weekly","remaining_fraction":0.8,"reset_time":"2026-11-20T17:25:18Z"}"#,
            thirdParty: #"{"id":"t","window":"weekly","remaining_fraction":0.34,"reset_time":"2026-11-20T17:25:18Z"}"#
        )).get()
        // (1 - 0.8) * 100 is 19.999999999999996: a 20% warning would not fire.
        XCTAssertEqual(s.buckets.map(\.usedPercent), [20, 66])
    }

    func testToleratesNoiseAroundTheJSONLine() throws {
        let s = try parse("[agy] warning: something\n" + output() + "\n").get()
        XCTAssertEqual(s.buckets.count, 2)
    }

    func testErrorStatusSurfacesTheCLIsMessage() {
        let text = """
        error: /usage failed: not signed in
        {"conversation_id":"","status":"ERROR","response":"","error":"/usage failed: not signed in","num_turns":0}
        """
        XCTAssertEqual(parse(text), .failure(GeminiReadError(message: "/usage failed: not signed in")))
    }

    func testGarbageIsAnError() {
        guard case .failure(let e) = parse("command not found") else { return XCTFail("expected failure") }
        XCTAssertFalse(e.message.isEmpty)
    }

    func testImplausibleBucketsAreSkipped() throws {
        let s = try parse(output(
            gemini: #"{"id":"gemini-weekly","window":"weekly","remaining_fraction":1e300,"reset_time":"2026-11-20T17:25:18Z"}"#
        )).get()
        XCTAssertEqual(s.buckets.map(\.id), ["3p-weekly"])
        XCTAssertEqual(parse(output(gemini: #"{"id":"g","window":"weekly","remaining_fraction":true,"reset_time":"2026-11-20T17:25:18Z"}"#))
            .map(\.buckets.count), .success(1))
        XCTAssertEqual(parse(output(gemini: #"{"id":"g","window":"weekly","remaining_fraction":0.5}"#))
            .map(\.buckets.count), .success(1), "no reset time: skipped")
    }

    func testNoUsableBucketsIsAnError() {
        let bad = #"{"id":"x","window":"weekly","remaining_fraction":-3,"reset_time":"2026-11-20T17:25:18Z"}"#
        guard case .failure = parse(output(gemini: bad, thirdParty: bad)) else { return XCTFail("expected failure") }
    }

    func testUnknownWindowHasNoLength() throws {
        let s = try parse(output(
            gemini: #"{"id":"gemini-daily","window":"daily","remaining_fraction":0.5,"reset_time":"2026-11-20T17:25:18Z"}"#,
            thirdParty: #"{"id":"odd","window":"fortnightly","remaining_fraction":0.5,"reset_time":"2026-11-20T17:25:18Z"}"#
        )).get()
        XCTAssertEqual(s.buckets.map(\.windowMinutes), [1440, nil])
        XCTAssertEqual(s.buckets[1].label, "Claude and GPT models fortnightly")
    }

    func testPeakUsesTheResetRule() {
        let s = GeminiSnapshot(buckets: [
            GeminiBucket(id: "a", group: "A", window: "weekly", usedPercent: 90, resetsAt: 10),
            GeminiBucket(id: "b", group: "B", window: "weekly", usedPercent: 30, resetsAt: 100),
        ], observedAt: 0)
        XCTAssertEqual(s.peakPercent(now: 5), 90)
        XCTAssertEqual(s.peakPercent(now: 11), 30, "a window past its reset counts as 0")
    }

    // MARK: Alerts

    private func snap(_ used: Double, resetsAt: Int64 = 1_000_000, observedAt: Int64 = 0) -> GeminiSnapshot {
        GeminiSnapshot(buckets: [GeminiBucket(id: "gemini-weekly", group: "Gemini Models", window: "weekly",
                                              usedPercent: used, resetsAt: resetsAt)], observedAt: observedAt)
    }

    func testCrossingsMatchBucketsDespiteResetJitter() {
        let c = GeminiSnapshot.crossings(previous: snap(70, resetsAt: 1_000_000), current: snap(85, resetsAt: 1_000_003),
                                         now: 0) { _ in [80, 100] }
        XCTAssertEqual(c.map(\.thresholds), [[80]])
    }

    /// An untouched bucket's reset rolls forward with every read; after a
    /// long sleep it has drifted by hours but is still the same window.
    func testCrossingsMatchAcrossLongResetDrift() {
        let c = GeminiSnapshot.crossings(previous: snap(0, resetsAt: 1_000_000, observedAt: 395_200),
                                         current: snap(85, resetsAt: 1_036_000, observedAt: 431_200),
                                         now: 431_200) { _ in [80] }
        XCTAssertEqual(c.map(\.thresholds), [[80]])
    }

    func testNoCrossingAcrossANewWindowOrAfterReset() {
        XCTAssertTrue(GeminiSnapshot.crossings(previous: snap(70, resetsAt: 1_000_000),
                                               current: snap(85, resetsAt: 1_604_800, observedAt: 1_000_001),
                                               now: 1_000_001) { _ in [80] }.isEmpty)
        XCTAssertTrue(GeminiSnapshot.crossings(previous: snap(70), current: snap(85), now: 2_000_000) { _ in [80] }.isEmpty)
        XCTAssertTrue(GeminiSnapshot.crossings(previous: nil, current: snap(85), now: 0) { _ in [80] }.isEmpty)
    }

    func testLatchSoundsOncePerWindowDespiteDrift() {
        var latch = GeminiAlertLatch()
        let a = snap(85, resetsAt: 1_000_000).buckets[0]
        let b = snap(85, resetsAt: 1_036_000).buckets[0]
        XCTAssertEqual(latch.admit([80], bucket: a, now: 0), [80])
        XCTAssertEqual(latch.admit([80], bucket: b, now: 36_000), [], "same window, reset drifted 10 h")
        let next = snap(85, resetsAt: 1_640_800).buckets[0]
        XCTAssertEqual(latch.admit([80], bucket: next, now: 1_036_001), [80], "the old window is over")
    }

    /// Quiet polls (no crossing) still carry the window's latest reset, so
    /// a later re-crossing in the same window stays silent.
    func testLatchFollowsResetDriftSeenOnQuietPolls() {
        var latch = GeminiAlertLatch()
        XCTAssertEqual(latch.admit([80], bucket: snap(85, resetsAt: 1_000_000).buckets[0], now: 0), [80])
        latch.observe(snap(70, resetsAt: 1_200_000), now: 100_000)
        XCTAssertEqual(latch.admit([80], bucket: snap(85, resetsAt: 1_200_000).buckets[0], now: 1_100_000), [])
    }

    // MARK: Store

    func testStoreRoundTripsAndClears() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-store-\(UUID().uuidString)/gemini.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(GeminiStore.read(at: url))
        let s = try parse(output()).get()
        try GeminiStore.write(s, to: url)
        XCTAssertEqual(GeminiStore.read(at: url), s)
        GeminiStore.clear(at: url)
        XCTAssertNil(GeminiStore.read(at: url))
    }

    // MARK: Finding the CLI

    func testFindsTheCLIInUsualPlacesThenTheLoginShell() {
        XCTAssertEqual(GeminiCLI.findCLI(home: "/u", isExecutable: { $0 == "/opt/homebrew/bin/agy" }, shellLookup: { nil }),
                       "/opt/homebrew/bin/agy")
        XCTAssertEqual(GeminiCLI.findCLI(home: "/u", isExecutable: { $0 == "/x/agy" }, shellLookup: { "/x/agy\n" }), "/x/agy")
        XCTAssertNil(GeminiCLI.findCLI(home: "/u", isExecutable: { _ in false }, shellLookup: { "agy not found" }))
    }

    func testUsageArgumentsDoNotDisableSlashCommands() {
        XCTAssertEqual(GeminiCLI.usageArguments, ["-p", "/usage", "--output-format", "json"])
    }
}
