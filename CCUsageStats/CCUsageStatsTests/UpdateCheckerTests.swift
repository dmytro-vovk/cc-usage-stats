import XCTest
@testable import CCUsageStats

final class AppVersionTests: XCTestCase {
    func testParsesTagWithAndWithoutPrefix() {
        XCTAssertEqual(AppVersion("v0.18.7"), AppVersion(major: 0, minor: 18, patch: 7))
        XCTAssertEqual(AppVersion("0.18.7"), AppVersion(major: 0, minor: 18, patch: 7))
        XCTAssertEqual(AppVersion("V1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
    }

    func testMissingComponentsAreZero() {
        XCTAssertEqual(AppVersion("1.2"), AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion("v2"), AppVersion(major: 2, minor: 0, patch: 0))
    }

    func testRejectsGarbage() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x.3"))
        XCTAssertNil(AppVersion("1.2.3.4"))
        XCTAssertNil(AppVersion("1..3"))
        XCTAssertNil(AppVersion("-1.2.3"))
    }

    func testComparesNumericallyNotLexically() {
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.18.7")!, AppVersion("0.18.10")!)
        XCTAssertLessThan(AppVersion("0.18.7")!, AppVersion("0.19.0")!)
        XCTAssertLessThan(AppVersion("0.99.99")!, AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("0.18.7")! < AppVersion("v0.18.7")!)
    }

    func testPreReleaseSortsBelowItsRelease() {
        XCTAssertLessThan(AppVersion("1.0.0-beta.1")!, AppVersion("1.0.0")!)
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0.0-rc1")!)
        XCTAssertEqual(AppVersion("1.0.0+build.5"), AppVersion("1.0.0"))
    }
}

final class LatestReleaseTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParsesTagPageAndDmg() throws {
        let r = try XCTUnwrap(LatestRelease.parse(json("""
        {"tag_name":"v0.19.0","html_url":"https://github.com/dmytro-vovk/cc-usage-stats/releases/tag/v0.19.0",
         "draft":false,"prerelease":false,
         "assets":[
           {"name":"CCUsageStats-v0.19.0.zip","browser_download_url":"https://github.com/x/y/releases/download/v0.19.0/CCUsageStats-v0.19.0.zip"},
           {"name":"CCUsageStats-v0.19.0.dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.19.0/CCUsageStats-v0.19.0.dmg"}
         ]}
        """)))
        XCTAssertEqual(r.tag, "v0.19.0")
        XCTAssertEqual(r.version, AppVersion(major: 0, minor: 19, patch: 0))
        XCTAssertEqual(r.pageURL.absoluteString, "https://github.com/dmytro-vovk/cc-usage-stats/releases/tag/v0.19.0")
        XCTAssertEqual(r.dmgURL?.lastPathComponent, "CCUsageStats-v0.19.0.dmg")
    }

    func testDmgIsOptional() throws {
        let r = try XCTUnwrap(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://github.com/a/b/releases/tag/v1.0.0","assets":[]}
        """)))
        XCTAssertNil(r.dmgURL)
    }

    func testRejectsDraftPrereleaseAndBadTag() {
        XCTAssertNil(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://github.com/a/b/releases/tag/v1.0.0","draft":true}
        """)))
        XCTAssertNil(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://github.com/a/b/releases/tag/v1.0.0","prerelease":true}
        """)))
        XCTAssertNil(LatestRelease.parse(json("""
        {"tag_name":"nightly","html_url":"https://github.com/a/b/releases/tag/nightly"}
        """)))
        XCTAssertNil(LatestRelease.parse(json(#"{"message":"Not Found"}"#)))
        XCTAssertNil(LatestRelease.parse(json("not json")))
    }

    /// Only GitHub https links are ever opened from the menu.
    func testRejectsNonGitHubPageURL() {
        XCTAssertNil(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"http://github.com/a/b/releases/tag/v1.0.0"}
        """)))
        XCTAssertNil(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://evil.example/releases/tag/v1.0.0"}
        """)))
        let r = LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://github.com/a/b/releases/tag/v1.0.0",
         "assets":[{"name":"x.dmg","browser_download_url":"https://evil.example/x.dmg"}]}
        """))
        XCTAssertNotNil(r)
        XCTAssertNil(r?.dmgURL, "a dmg link off github.com is dropped, not followed")
    }
}

final class GitHubReleaseResponseTests: XCTestCase {
    private let ok = Data("""
    {"tag_name":"v0.19.0","html_url":"https://github.com/a/b/releases/tag/v0.19.0"}
    """.utf8)

    func testSuccess() {
        guard case .release(let r) = GitHubReleaseClient.classify(status: 200, headers: [:], body: ok, now: 0) else {
            return XCTFail("expected release")
        }
        XCTAssertEqual(r.tag, "v0.19.0")
    }

    func testUnparseable200IsFailure() {
        XCTAssertEqual(GitHubReleaseClient.classify(status: 200, headers: [:], body: Data("{}".utf8), now: 0), .failure)
    }

    func testRetryAfterHeaderWins() {
        XCTAssertEqual(
            GitHubReleaseClient.classify(status: 429, headers: ["Retry-After": "120"], body: Data(), now: 0),
            .rateLimited(retryAfter: 120)
        )
    }

    func testPrimaryLimitUsesResetEpoch() {
        let headers = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1000"]
        XCTAssertEqual(
            GitHubReleaseClient.classify(status: 403, headers: headers, body: Data(), now: 400),
            .rateLimited(retryAfter: 600)
        )
    }

    func testHeaderNamesAreCaseInsensitive() {
        let headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000"]
        XCTAssertEqual(
            GitHubReleaseClient.classify(status: 403, headers: headers, body: Data(), now: 400),
            .rateLimited(retryAfter: 600)
        )
    }

    func testRateLimitWithoutHintHasNilRetry() {
        XCTAssertEqual(GitHubReleaseClient.classify(status: 429, headers: [:], body: Data(), now: 0),
                       .rateLimited(retryAfter: nil))
    }

    /// A 403 with quota left is not a rate limit (e.g. blocked), just a failure.
    func testPlain403IsFailure() {
        XCTAssertEqual(
            GitHubReleaseClient.classify(status: 403, headers: ["x-ratelimit-remaining": "42"], body: Data(), now: 0),
            .failure
        )
    }

    func testServerErrorAndNotFoundAreFailures() {
        XCTAssertEqual(GitHubReleaseClient.classify(status: 500, headers: [:], body: ok, now: 0), .failure)
        XCTAssertEqual(GitHubReleaseClient.classify(status: 404, headers: [:], body: ok, now: 0), .failure)
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    final class StubClient: UpdateCheckClient {
        var queue: [UpdateFetchResult] = []
        var calls = 0
        func fetchLatest() async -> UpdateFetchResult {
            calls += 1
            return queue.isEmpty ? .failure : queue.removeFirst()
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var now: Int64 = 1_000_000

    override func setUp() {
        super.setUp()
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func release(_ tag: String) -> LatestRelease {
        LatestRelease(tag: tag, version: AppVersion(tag)!,
                      pageURL: URL(string: "https://github.com/a/b/releases/tag/\(tag)")!, dmgURL: nil)
    }

    private func makeChecker(current: String?, client: StubClient) -> UpdateChecker {
        UpdateChecker(client: client, currentVersion: current, defaults: defaults, clock: { [unowned self] in self.now })
    }

    // MARK: delays

    func testDelayAfterSuccessIsDaily() {
        XCTAssertEqual(UpdateChecker.delay(after: .release(release("v1.0.0")), failures: 0), 24 * 3600)
    }

    func testFailureBackoffDoublesAndCaps() {
        XCTAssertEqual(UpdateChecker.delay(after: .failure, failures: 1), 30 * 60)
        XCTAssertEqual(UpdateChecker.delay(after: .failure, failures: 2), 60 * 60)
        XCTAssertEqual(UpdateChecker.delay(after: .failure, failures: 3), 2 * 3600)
        XCTAssertEqual(UpdateChecker.delay(after: .failure, failures: 10), 24 * 3600)
        XCTAssertEqual(UpdateChecker.delay(after: .failure, failures: 500), 24 * 3600, "no overflow")
    }

    func testRateLimitHonoursRetryAfterWithinBounds() {
        XCTAssertEqual(UpdateChecker.delay(after: .rateLimited(retryAfter: 2 * 3600), failures: 1), 2 * 3600)
        XCTAssertEqual(UpdateChecker.delay(after: .rateLimited(retryAfter: 5), failures: 1), 15 * 60,
                       "never re-asks sooner than the floor")
        XCTAssertEqual(UpdateChecker.delay(after: .rateLimited(retryAfter: 9 * 24 * 3600), failures: 1), 24 * 3600)
        XCTAssertEqual(UpdateChecker.delay(after: .rateLimited(retryAfter: nil), failures: 1), 3600)
    }

    // MARK: ticks

    func testNewerReleaseIsPublished() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertEqual(c.available?.tag, "v0.19.0")
        XCTAssertEqual(c.nextDelay, 24 * 3600)
        XCTAssertEqual(c.lastCheckedAt, now)
    }

    func testSameOrOlderReleaseIsNotPublished() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7")), .release(release("v0.18.6"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertNil(c.available)
        await c.tickForTest()
        XCTAssertNil(c.available)
    }

    /// Once the user installs the update, a later check that finds the
    /// running version is current clears the row.
    func testLaterCurrentAnswerClearsAvailable() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.18.7"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertNotNil(c.available)
        await c.tickForTest()
        XCTAssertNil(c.available)
    }

    func testFailureKeepsPreviousAnswerAndBacksOff() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .failure, .failure, .release(release("v0.19.0"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        await c.tickForTest()
        XCTAssertEqual(c.available?.tag, "v0.19.0", "a failed check doesn't flap the row")
        XCTAssertEqual(c.consecutiveFailures, 1)
        XCTAssertEqual(c.nextDelay, 30 * 60)
        await c.tickForTest()
        XCTAssertEqual(c.nextDelay, 60 * 60)
        await c.tickForTest()
        XCTAssertEqual(c.consecutiveFailures, 0, "success resets the backoff")
        XCTAssertEqual(c.nextDelay, 24 * 3600)
    }

    func testRateLimitSchedulesRetryAfter() async {
        let client = StubClient()
        client.queue = [.rateLimited(retryAfter: 5400)]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertEqual(c.nextDelay, 5400)
    }

    /// Builds without a real version (Xcode runs report 0.0.0) never
    /// call GitHub: every release would look newer.
    func testDevBuildNeverChecks() async {
        for current in [nil, "0.0.0", "garbage"] {
            let client = StubClient()
            client.queue = [.release(release("v9.0.0"))]
            let c = makeChecker(current: current, client: client)
            await c.tickForTest()
            XCTAssertEqual(client.calls, 0, "current=\(current ?? "nil")")
            XCTAssertNil(c.available)
        }
    }

    // MARK: setting

    func testEnabledDefaultsToOnAndPersists() {
        let c = makeChecker(current: "0.18.7", client: StubClient())
        XCTAssertTrue(c.enabled)
        c.enabled = false
        XCTAssertFalse(makeChecker(current: "0.18.7", client: StubClient()).enabled)
    }

    func testDisabledSkipsNetworkAndClearsRow() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.19.0"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertNotNil(c.available)
        c.enabled = false
        XCTAssertNil(c.available, "turning the check off hides the row")
        await c.tickForTest()
        XCTAssertEqual(client.calls, 1)
    }

    // MARK: due-ness (wake from sleep)

    func testIsDueOnlyAfterScheduledDelay() async {
        let client = StubClient()
        client.queue = [.failure]
        let c = makeChecker(current: "0.18.7", client: client)
        XCTAssertTrue(c.isDue, "never checked")
        await c.tickForTest()
        now += 30 * 60 - 1
        XCTAssertFalse(c.isDue)
        now += 1
        XCTAssertTrue(c.isDue)
    }
}
