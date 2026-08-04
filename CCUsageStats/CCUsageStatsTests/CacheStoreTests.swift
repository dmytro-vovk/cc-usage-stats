import XCTest
@testable import CCUsageStats

@MainActor
final class CacheStoreTests: XCTestCase {
    private var tmpFile: URL!

    override func setUpWithError() throws {
        tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpFile)
    }

    func testReadAbsentReturnsNil() throws {
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testReadCorruptReturnsNil() throws {
        try Data("garbage".utf8).write(to: tmpFile)
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testWriteAndReadRoundTrip() throws {
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 42, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 18, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 50)
        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 50)
        XCTAssertEqual(read.snapshot, snapshot)
    }

    func testMergePreservesAbsentField() throws {
        let initial = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: initial, now: 50)

        let onlyFive = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 12, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: onlyFive, now: 60)

        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 60)
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 12)
        XCTAssertEqual(read.snapshot.sevenDay?.usedPercentage, 20, "seven_day must be preserved when absent from new payload")
    }

    func testWriteIsAtomic() throws {
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 1)
        let dir = tmpFile.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(tmpFile.lastPathComponent) && $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testModelWindowsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snap = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200),
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: 93, resetsAt: 300)]
        )
        try CacheStore.update(at: url, with: snap, now: 42)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 93)
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.resetsAt, 300)
    }

    func testOldFormatFileDecodesWithEmptyModels() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-oldformat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Exactly the shape written by versions before this feature.
        let legacy = """
        {"captured_at":42,"five_hour":{"used_percentage":10,"resets_at":100}}
        """
        try Data(legacy.utf8).write(to: url)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 10)
        XCTAssertTrue(read.snapshot.models.isEmpty)
    }

    // MARK: - Model windows: only a source that can see them may define them
    //
    // These four replace a `testModelWindowsMergePerKey` that asserted the
    // opposite — that a poll omitting a model key preserved the on-disk
    // value. That assertion encoded a bug rather than a requirement.
    //
    // `captured_at` is snapshot-wide and is re-stamped by every poll from
    // *any* source. Under per-key preservation, a connected user whose grant
    // later died fell back to the header path — which cannot see model
    // windows at all and therefore always sends an empty set — and the merge
    // kept the last per-model number alive indefinitely while `captured_at`
    // advanced every minute. The dropdown then rendered "Opus weekly · 83% ·
    // Resets in 5d 23h" at full non-stale alpha directly above "Last updated
    // 4s ago", the pill grew a third segment for it, and the same dropdown
    // offered to connect the account that used to produce it. Nothing could
    // ever refresh or retire that number.
    //
    // The rule instead: an authoritative source (`GET /api/oauth/usage`)
    // states the whole set, and a source that cannot see model windows
    // clears them. Do not reinstate per-key preservation.

    private func authoritative(_ models: [String: Double]) -> RateLimitsSnapshot {
        RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 9_999),
            sevenDay: nil,
            models: models.mapValues { WindowSnapshot(usedPercentage: $0, resetsAt: 9_999) }
        )
    }

    /// Header-path shape: the two-window initializer, which is the only one
    /// `AnthropicAPI.parseHeaders` can use.
    private func headerOnly(five: Double) -> RateLimitsSnapshot {
        RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: five, resetsAt: 9_999),
            sevenDay: nil
        )
    }

    /// The endpoint is the complete statement, so a key it stops reporting is
    /// gone — not merely unmentioned.
    func testAuthoritativePollReplacesTheWholeModelSet() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-replace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try CacheStore.update(at: url, with: authoritative([
            "seven_day_fable": 50, "seven_day_sonnet": 60,
        ]), now: 1)
        try CacheStore.update(at: url, with: authoritative(["seven_day_fable": 55]), now: 2)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 55)
        XCTAssertNil(read.snapshot.models["seven_day_sonnet"],
                     "a key the authoritative source stopped reporting is gone")
    }

    /// The Critical, end to end at the store: the header path must not keep a
    /// per-model number alive under a `captured_at` it keeps refreshing.
    func testHeaderPollClearsModelWindowsItCannotSee() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try CacheStore.update(at: url, with: authoritative(["seven_day_opus": 83]), now: 1)
        XCTAssertFalse(try XCTUnwrap(CacheStore.read(at: url)).snapshot.models.isEmpty)

        // The grant dies; the poller falls back to the header path.
        try CacheStore.update(at: url, with: headerOnly(five: 42), now: 2)

        let read = try XCTUnwrap(CacheStore.read(at: url))
        XCTAssertEqual(read.capturedAt, 2)
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 42)
        XCTAssertTrue(read.snapshot.models.isEmpty,
                      "a source that cannot see model windows must not keep stale ones alive")
    }

    /// "This account has no per-model window" is a real answer from a source
    /// that can see them, and an empty dictionary alone cannot be told apart
    /// from "I have nothing to say" — which is exactly why the snapshot
    /// carries the distinction rather than inferring it.
    func testAuthoritativeEmptySetClearsModelWindows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-usage-model-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try CacheStore.update(at: url, with: authoritative(["seven_day_opus": 83]), now: 1)
        try CacheStore.update(at: url, with: authoritative([:]), now: 2)

        XCTAssertTrue(try XCTUnwrap(CacheStore.read(at: url)).snapshot.models.isEmpty)
    }

    /// The two initializers are the whole mechanism, so pin what each claims
    /// — and pin that the two real parsers pick the right one. Swapping them
    /// is the one edit that would silently restore the old behaviour.
    func testOnlyTheModelsInitializerClaimsAuthority() throws {
        XCTAssertFalse(RateLimitsSnapshot(fiveHour: nil, sevenDay: nil).modelsAreAuthoritative)
        XCTAssertTrue(
            RateLimitsSnapshot(fiveHour: nil, sevenDay: nil, models: [:]).modelsAreAuthoritative,
            "passing models at all is the claim that this source can see them"
        )

        let headerResult = AnthropicAPI.parse(
            status: 200,
            headers: [
                "anthropic-ratelimit-unified-5h-utilization": "0.42",
                "anthropic-ratelimit-unified-5h-reset": "9999",
            ],
            body: Data()
        )
        guard case .success(let fromHeaders) = headerResult else {
            return XCTFail("expected .success from the header path, got \(headerResult)")
        }
        XCTAssertFalse(fromHeaders.modelsAreAuthoritative,
                       "the header path cannot see model windows and must not claim to")

        let fromEndpoint = try XCTUnwrap(OAuthUsage.parseBody(Data("""
        {"five_hour":{"utilization":42,"resets_at":"2026-08-04T12:00:00Z"}}
        """.utf8)))
        XCTAssertTrue(fromEndpoint.modelsAreAuthoritative,
                      "the usage endpoint states the whole set, empty or not")
        XCTAssertTrue(fromEndpoint.models.isEmpty)
    }

    /// `init(from:)` derives the flag rather than reading it — the file never
    /// carries it. Nothing in production consults a *decoded* value:
    /// `CacheStore.update` reads the flag only off the freshly-parsed
    /// `incoming` snapshot, and `incoming` always comes from a parser. This
    /// pins the derivation anyway so the property stays self-consistent (a
    /// decoded snapshot with model windows must claim authority, or a future
    /// read-modify-write through `update` would clear the very rows it just
    /// read back) and so the rule is stated somewhere executable rather than
    /// only in a comment.
    func testDecodingDerivesAuthorityFromWhetherModelsWerePersisted() throws {
        let withModels = try JSONDecoder().decode(RateLimitsSnapshot.self, from: Data("""
        {"model_windows":{"seven_day_opus":{"used_percentage":50,"resets_at":9999}}}
        """.utf8))
        XCTAssertTrue(withModels.modelsAreAuthoritative,
                      "model windows only ever reach the file from an authoritative source")

        let withoutModels = try JSONDecoder().decode(RateLimitsSnapshot.self, from: Data("""
        {"five_hour":{"used_percentage":10,"resets_at":9999}}
        """.utf8))
        XCTAssertFalse(withoutModels.modelsAreAuthoritative,
                       "a legacy or header-written file states nothing about model windows")
    }
}
