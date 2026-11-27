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

    func testParsesTheTag() throws {
        let r = try XCTUnwrap(LatestRelease.parse(json("""
        {"tag_name":"v0.19.0","html_url":"https://github.com/dmytro-vovk/cc-usage-stats/releases/tag/v0.19.0",
         "draft":false,"prerelease":false,
         "assets":[
           {"name":"CCUsageStats-v0.19.0.dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.19.0/CCUsageStats-v0.19.0.dmg"}
         ]}
        """)))
        XCTAssertEqual(r.tag, "v0.19.0")
        XCTAssertEqual(r.version, AppVersion(major: 0, minor: 19, patch: 0))
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

    /// No URL in the response is used, so none can disqualify (or steer) it:
    /// the app's links all open the constant `AppLinks.website`.
    func testURLsInTheResponseAreIgnored() throws {
        let r = try XCTUnwrap(LatestRelease.parse(json("""
        {"tag_name":"v1.0.0","html_url":"https://evil.example/releases/tag/v1.0.0",
         "assets":[{"name":"x.dmg","browser_download_url":"https://evil.example/x.dmg"}]}
        """)))
        XCTAssertEqual(r, LatestRelease(tag: "v1.0.0", version: AppVersion(major: 1, minor: 0, patch: 0)))
        XCTAssertNotNil(LatestRelease.parse(json(#"{"tag_name":"v1.0.0"}"#)))
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
        /// Runs while the request is "in flight".
        var onFetch: (() -> Void)?
        /// Awaited while the request is "in flight".
        var whileFetching: (() async -> Void)?
        func fetchLatest() async -> UpdateFetchResult {
            calls += 1
            onFetch?()
            if let w = whileFetching { whileFetching = nil; await w() }
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
        LatestRelease(tag: tag, version: AppVersion(tag)!)
    }

    final class SpyNotifier: UpdateNotifying {
        var posted: [String] = []
        /// What the system would answer: false = refused, unanswered or failed.
        var succeeds = true
        func notify(_ release: LatestRelease) async -> Bool {
            posted.append(release.tag)
            return succeeds
        }
    }

    private func makeChecker(
        current: String?, client: StubClient, notifier: UpdateNotifying? = nil,
        sleep: @escaping (TimeInterval) async throws -> Void = { _ in }
    ) -> UpdateChecker {
        UpdateChecker(client: client, currentVersion: current, defaults: defaults, notifier: notifier,
                      clock: { [unowned self] in self.now }, sleep: sleep)
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

    // MARK: review follow-ups

    func testDisablingMidFetchDropsTheAnswer() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let c = makeChecker(current: "0.18.7", client: client)
        client.onFetch = { c.enabled = false }
        await c.tickForTest()
        XCTAssertEqual(client.calls, 1)
        XCTAssertNil(c.available)
        XCTAssertNil(c.lastCheckedAt)
    }

    func testDevBuildCannotCheck() {
        XCTAssertFalse(makeChecker(current: "0.0.0", client: StubClient()).canCheck)
        XCTAssertTrue(makeChecker(current: "0.18.7", client: StubClient()).canCheck)
    }

    /// "Check now" must not defeat GitHub's Retry-After.
    func testCheckNowWaitsOutARateLimit() async {
        let client = StubClient()
        client.queue = [.rateLimited(retryAfter: 1800)]
        let c = makeChecker(current: "0.18.7", client: client)
        XCTAssertTrue(c.canCheckNow)
        await c.tickForTest()
        XCTAssertFalse(c.canCheckNow)
        now += 1800
        XCTAssertTrue(c.canCheckNow)
    }

    func testCheckNowAllowedAfterPlainFailure() async {
        let client = StubClient()
        client.queue = [.failure]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertTrue(c.canCheckNow)
    }

    func testCheckNowDisabledWhenOff() {
        let c = makeChecker(current: "0.18.7", client: StubClient())
        c.enabled = false
        XCTAssertFalse(c.canCheckNow)
    }

    // MARK: notification

    func testNewerReleasePostsNotificationOnce() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        await c.tickForTest()
        let posted = spy.posted
        XCTAssertEqual(posted, ["v0.19.0"], "one notification per release, not one per daily check")
    }

    /// A relaunch still on the old version must not repeat the notification
    /// for a release it already announced.
    func testAnnouncedReleaseIsNotRepeatedAfterRelaunch() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.19.0"))]
        let spy = SpyNotifier()
        await makeChecker(current: "0.18.7", client: client, notifier: spy).tickForTest()
        await makeChecker(current: "0.18.7", client: client, notifier: spy).tickForTest()
        let posted = spy.posted
        XCTAssertEqual(posted, ["v0.19.0"])
    }

    func testEachNewerReleaseIsAnnounced() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.19.1"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        await c.tickForTest()
        let posted = spy.posted
        XCTAssertEqual(posted, ["v0.19.0", "v0.19.1"])
    }

    func testCurrentOrFailedCheckDoesNotNotify() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7")), .failure, .rateLimited(retryAfter: nil)]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        await c.tickForTest()
        await c.tickForTest()
        let posted = spy.posted
        XCTAssertEqual(posted, [])
    }

    /// A notification that never reached the system (permission prompt
    /// unanswered or refused, post failed) has not announced the release:
    /// the next check tries again, and stops once one goes through.
    func testAnnouncementThatWasNotPostedIsRetried() async {
        let spy = SpyNotifier()
        spy.succeeds = false
        let client = StubClient()
        client.queue = Array(repeating: .release(release("v0.19.0")), count: 3)
        let checker = makeChecker(current: "0.18.0", client: client, notifier: spy)
        await checker.tickForTest()
        XCTAssertNil(defaults.string(forKey: UpdateChecker.notifiedTagKey))
        spy.succeeds = true
        await checker.tickForTest()
        await checker.tickForTest()
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.notifiedTagKey), "v0.19.0")
    }

    /// Without a notifier nothing was announced, so nothing is recorded.
    func testNoNotifierRecordsNoAnnouncement() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let checker = makeChecker(current: "0.18.0", client: client)
        await checker.tickForTest()
        XCTAssertNil(defaults.string(forKey: UpdateChecker.notifiedTagKey))
    }

    // MARK: unlock delay

    /// A banner posted the instant the screen unlocks lands on a desktop
    /// that is still coming up. The unlock is acted on a minute later.
    func testUnlockRemindsOnlyAfterTheDelay() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        var waits: [TimeInterval] = []
        var postedWhenTheWaitBegan = -1
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy, sleep: {
            waits.append($0)
            postedWhenTheWaitBegan = spy.posted.count
        })
        await c.tickForTest()                       // announced by the timer
        c.start()
        defer { c.stop() }
        c.screenUnlocked()
        await c.unlockSettledForTest()
        XCTAssertEqual(waits, [60])
        XCTAssertEqual(postedWhenTheWaitBegan, 1, "nothing is posted before the wait")
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
    }

    /// Locked again inside the minute: nobody is there to see it, and the
    /// day's reminder must be left for the next unlock.
    func testLockingAgainWithinTheDelayCancelsTheReminder() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        var waits = 0
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy, sleep: { _ in
            waits += 1
            if waits == 1 { try await Task.sleep(nanoseconds: 30_000_000_000) }
        })
        await c.tickForTest()
        c.start()
        defer { c.stop() }
        c.screenUnlocked()
        c.screenLocked()
        await c.unlockSettledForTest()
        XCTAssertEqual(spy.posted, ["v0.19.0"], "cancelled: no reminder")

        c.screenUnlocked()
        await c.unlockSettledForTest()
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"], "the next unlock still reminds today")
    }

    /// Two unlocks inside the minute are one sit-down, not two.
    func testASecondUnlockRestartsTheWait() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        var waits = 0
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy, sleep: { _ in
            waits += 1
            if waits == 1 { try await Task.sleep(nanoseconds: 30_000_000_000) }
        })
        await c.tickForTest()
        c.start()
        defer { c.stop() }
        c.screenUnlocked()
        await Task.yield()
        c.screenUnlocked()
        await c.unlockSettledForTest()
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
    }

    func testStoppingCancelsAPendingUnlock() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy, sleep: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
        })
        await c.tickForTest()
        c.start()
        c.screenUnlocked()
        c.stop()
        await c.unlockSettledForTest()
        XCTAssertEqual(spy.posted, ["v0.19.0"])
    }

    /// Update banners stay until dismissed unless the user picks otherwise:
    /// a temporary one is gone in seconds, seen or not.
    func testNotificationsDefaultToThePersistentStyle() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSUserNotificationAlertStyle") as? String, "alert")
    }

    // MARK: screen unlock

    /// Unlocking after the last check went stale asks GitHub again and
    /// announces a newer release right then, while the user is looking.
    func testUnlockRechecksWhenStaleAndAnnounces() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7")), .release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        now += Int64(UpdateChecker.unlockRecheck)
        await c.handleUnlockForTest()
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(spy.posted, ["v0.19.0"])
    }

    func testUnlockSoonAfterACheckDoesNotHitGitHub() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        now += Int64(UpdateChecker.unlockRecheck) - 1
        await c.handleUnlockForTest()
        XCTAssertEqual(client.calls, 1)
    }

    /// Before the first (launch) check has run, unlock leaves it to the timer.
    func testUnlockBeforeFirstCheckDoesNothing() async {
        let client = StubClient()
        let c = makeChecker(current: "0.18.7", client: client)
        await c.handleUnlockForTest()
        XCTAssertEqual(client.calls, 0)
    }

    /// Still behind: the first unlock of each day reminds again, even though
    /// the release was announced already (maybe while the screen was locked).
    func testUnlockRemindsOncePerDayWhileBehind() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()                       // announced by the timer
        await c.handleUnlockForTest()               // same day: first unlock reminds
        await c.handleUnlockForTest()               // same day again: quiet
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
        client.queue = [.release(release("v0.19.0"))]
        now += 24 * 3600
        await c.handleUnlockForTest()               // next day: stale, rechecks, reminds
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0", "v0.19.0"])
    }

    func testUnlockWhenCurrentNeverNotifies() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        await c.handleUnlockForTest()
        XCTAssertEqual(spy.posted, [])
    }

    func testUnlockWhenOffDoesNothing() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        c.enabled = false
        now += 24 * 3600
        await c.handleUnlockForTest()
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(spy.posted, ["v0.19.0"])
    }

    /// A reminder that never reached the system does not use up the day.
    func testFailedReminderIsRetriedOnNextUnlock() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        spy.succeeds = false
        await c.handleUnlockForTest()
        spy.succeeds = true
        await c.handleUnlockForTest()
        await c.handleUnlockForTest()
        XCTAssertEqual(spy.posted.count, 3)
    }

    // MARK: version status (dropdown icon)

    func testStatusUnknownBeforeAnyCheck() {
        XCTAssertEqual(makeChecker(current: "0.18.7", client: StubClient()).status, .unknown)
    }

    func testStatusCurrentAfterSuccessfulCheck() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertEqual(c.status, .current)
    }

    func testStatusOutdatedWhenNewerExists() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        XCTAssertEqual(c.status, .outdated)
    }

    func testStatusCheckingWhileInFlight() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7"))]
        let c = makeChecker(current: "0.18.7", client: client)
        var seen: UpdateChecker.Status?
        client.onFetch = { seen = c.status }
        await c.tickForTest()
        XCTAssertEqual(seen, .checking)
    }

    /// A failed check keeps the last known answer rather than guessing.
    func testStatusKeepsLastAnswerAfterFailure() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7")), .failure]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        await c.tickForTest()
        XCTAssertEqual(c.status, .current)
    }

    func testStatusUnknownWhenOffOrDevBuild() async {
        let client = StubClient()
        client.queue = [.release(release("v0.18.7"))]
        let c = makeChecker(current: "0.18.7", client: client)
        await c.tickForTest()
        c.enabled = false
        XCTAssertEqual(c.status, .unknown)
        XCTAssertEqual(makeChecker(current: "0.0.0", client: StubClient()).status, .unknown)
    }

    /// The morning case: wake starts a check, the unlock lands while it is
    /// in flight. The reminder must follow that check, not be dropped.
    func testUnlockDuringInFlightCheckRemindsAfterIt() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .release(release("v0.19.0"))]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()                       // announced
        var askedGitHub: Bool?
        client.whileFetching = { askedGitHub = await c.handleUnlock() }
        await c.tickForTest()                       // unlock arrives mid-fetch
        XCTAssertEqual(askedGitHub, false)
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
    }

    /// Network not up yet right after unlock: the recheck fails, but the
    /// release found earlier is still waiting, so remind anyway.
    func testFailedUnlockRecheckStillReminds() async {
        let client = StubClient()
        client.queue = [.release(release("v0.19.0")), .failure]
        let spy = SpyNotifier()
        let c = makeChecker(current: "0.18.7", client: client, notifier: spy)
        await c.tickForTest()
        now += 24 * 3600
        await c.handleUnlockForTest()
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(spy.posted, ["v0.19.0", "v0.19.0"])
    }
}
