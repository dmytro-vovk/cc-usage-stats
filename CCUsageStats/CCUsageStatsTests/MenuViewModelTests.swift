import Combine
import XCTest
@testable import CCUsageStats

/// Coverage for the recovery-hint lifecycle and the token states around it —
/// the wiring that had none, and where a stale message under a healthy readout
/// came from in the first place.
///
/// `start()` is deliberately never called: it opens file watchers, timers and a
/// status poller, and no-ops under test anyway. Everything else here drives the
/// state machine through `attachPoller` (via `restartPollingForTest()`), which
/// reads `OAuthSessionStore` and, when a scoped session is present, builds the
/// scoped client. Both client factories are injected — `apiFactory` for the
/// header-fallback path and `oauthClientFactory` for the scoped one — so no
/// test here can reach `api.anthropic.com`, including the connect tests, which
/// do store a session. `setUp`/`tearDown` clear both Keychain items so nothing
/// leaks between tests.
@MainActor
final class MenuViewModelTests: XCTestCase {
    private let deadline = Date(timeIntervalSince1970: 1_785_000_000)

    override func setUpWithError() throws {
        try? TokenStore.delete()
        try? OAuthSessionStore.delete()
    }
    override func tearDownWithError() throws {
        try? TokenStore.delete()
        try? OAuthSessionStore.delete()
    }

    /// Every stubbed poll answers the same way, so `authState` is decided by
    /// the test rather than by the network.
    private struct StubAPI: AnthropicAPIClient {
        let result: AnthropicAPI.Result
        func fetchRateLimits() async -> AnthropicAPI.Result { result }
    }

    private func viewModel(polling result: AnthropicAPI.Result = .invalidToken) -> MenuViewModel {
        MenuViewModel(
            apiFactory: { _ in StubAPI(result: result) },
            oauthClientFactory: { _ in StubAPI(result: result) }
        )
    }

    /// A view model whose browser authorization is `flow` instead of a real
    /// PKCE round-trip.
    private func viewModel(
        polling result: AnthropicAPI.Result = .invalidToken,
        connect flow: @escaping () async throws -> OAuthSession
    ) -> MenuViewModel {
        MenuViewModel(
            apiFactory: { _ in StubAPI(result: result) },
            oauthClientFactory: { _ in StubAPI(result: result) },
            connectFlow: flow
        )
    }

    private func session(scopes: [String]) -> OAuthSession {
        OAuthSession(accessToken: "at", refreshToken: "rt", expiresAt: 9_999_999_999, scopes: scopes)
    }

    /// Mutable counter shared with an escaping closure.
    private final class CallCount { var value = 0 }

    /// A latch the test opens by hand, so "the flow is still in flight" is a
    /// fact rather than a sleep.
    private final class Latch {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - The hint appears with the reason attached

    func testFailedReimportPublishesTheProbeReason() {
        let vm = viewModel()
        vm.reimportFromClaudeCodeKeychain { .expired(self.deadline) }
        XCTAssertEqual(
            vm.recoveryHint,
            RecoveryCopy.message(for: .noneAvailable(.expired(deadline)), now: Date())
        )
    }

    func testEachProbeMissProducesItsOwnHint() {
        var hints: Set<String> = []
        for miss: ClaudeCodeKeychainProbe.Outcome in [.expired(deadline), .accessDenied, .noClaudeToken, .noEntries] {
            let vm = viewModel()
            vm.reimportFromClaudeCodeKeychain { miss }
            hints.insert(vm.recoveryHint ?? "")
        }
        XCTAssertEqual(hints.count, 4)
    }

    /// The Keychain holding the very token that just 401'd is its own message —
    /// re-importing it would walk back into the same failure.
    func testReimportingTheRejectedTokenSaysSo() throws {
        try TokenStore.write("sk-ant-oat01-rejected")
        let vm = viewModel()
        vm.reimportFromClaudeCodeKeychain {
            .found(.init(token: "sk-ant-oat01-rejected", expiresAt: nil))
        }
        XCTAssertEqual(vm.recoveryHint, RecoveryCopy.message(for: .sameTokenRejected, now: Date()))
    }

    // MARK: - …and cannot outlive the failure it describes

    func testASuccessfulPollClearsTheHint() {
        let vm = viewModel()
        vm.reimportFromClaudeCodeKeychain { .noEntries }
        XCTAssertNotNil(vm.recoveryHint)

        vm.applyAuthState(.ok)
        XCTAssertNil(vm.recoveryHint, "a poll succeeded — the explanation is no longer true")
    }

    func testEveryNonTokenStateClearsTheHint() {
        for state: AuthState in [.ok, .notSubscriber, .offline, .unknown] {
            let vm = viewModel()
            vm.reimportFromClaudeCodeKeychain { .noEntries }
            vm.applyAuthState(state)
            XCTAssertNil(vm.recoveryHint, "\(state) should retire the hint")
        }
    }

    /// The states where the hint is the whole point: it has to survive them.
    func testTokenTroubleStatesKeepTheHint() {
        for state: AuthState in [.noToken, .invalidToken] {
            let vm = viewModel()
            vm.reimportFromClaudeCodeKeychain { .noEntries }
            vm.applyAuthState(state)
            XCTAssertNotNil(vm.recoveryHint, "\(state) still needs its explanation")
        }
    }

    /// Adopting a token restarts polling, and a message about the previous
    /// failure must not ride along into the new session.
    func testAdoptingATokenClearsTheHintAndStoresIt() throws {
        let vm = viewModel(polling: .invalidToken)
        vm.reimportFromClaudeCodeKeychain { .noEntries }
        XCTAssertNotNil(vm.recoveryHint)

        vm.reimportFromClaudeCodeKeychain {
            .found(.init(token: "sk-ant-oat01-adopted", expiresAt: self.deadline))
        }
        XCTAssertNil(vm.recoveryHint)
        XCTAssertEqual(TokenStore.readStored(),
                       StoredToken(token: "sk-ant-oat01-adopted", expiresAt: self.deadline))
    }

    // MARK: - No token is not a rejected token

    func testAdoptingIntoAnEmptyKeychainLeavesNoTokenBehind() {
        let vm = viewModel()
        XCTAssertEqual(vm.authState, .unknown)

        // Nothing stored and nothing to import: the state must say "no token",
        // never "rejected" — the API has said nothing at all.
        vm.reimportFromClaudeCodeKeychain { .noEntries }
        XCTAssertNotEqual(vm.authState, .invalidToken)
    }

    func testHintSurvivesTheNoTokenStateItWasProducedIn() {
        let vm = viewModel()
        vm.applyAuthState(.noToken)
        vm.reimportFromClaudeCodeKeychain { .accessDenied }
        vm.applyAuthState(.noToken)
        XCTAssertNotNil(vm.recoveryHint)
    }

    // MARK: - Reconnect flag

    /// Pumps the main run loop so a Combine `.receive(on: RunLoop.main)` sink
    /// gets a chance to deliver before the next assertion. `wait(for:)`
    /// services both dispatch-main-queue blocks and RunLoop-scheduled work,
    /// so the `DispatchQueue.main.async` fulfillment only completes once
    /// everything already queued ahead of it — including the poller's
    /// `$needsReauthorization` republish — has run.
    private func pumpMainRunLoop() {
        let pumped = expectation(description: "main run loop pumped")
        DispatchQueue.main.async { pumped.fulfill() }
        wait(for: [pumped], timeout: 2.0)
    }

    func testReconnectFlagSetWhenOnlyAPastedTokenExists() throws {
        try TokenStore.write("sk-ant-oat01-stub")
        let vm = viewModel(polling: .success(
            RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 2),
                               sevenDay: nil)
        ))
        vm.restartPollingForTest()
        XCTAssertTrue(vm.needsReauthorization,
                      "a header-only user must be told the model meter needs connecting")

        // The synchronous assignment above only proves attachPoller's initial
        // value. The poller also mirrors its own `$needsReauthorization`
        // through a `.receive(on: RunLoop.main)` sink that ORs in the static
        // "no scoped session" fact — without that OR, this republish would
        // flip the flag to false the moment the poller's own (successful,
        // so false) value lands. Pump the run loop so that sink actually
        // fires, then re-assert.
        pumpMainRunLoop()
        XCTAssertTrue(vm.needsReauthorization,
                      "must still be true after the poller's own flag republishes on the next run-loop turn")
    }

    // MARK: - Connect

    /// The flow can hand back a session that was granted less than we asked
    /// for. Storing it made `attachPoller` refuse to use it and fall through
    /// to the pasted-token branch: the user completed the browser flow, saw
    /// the success page, and nothing changed — no error, no data, forever.
    func testConnectWithoutProfileScopeIsReportedAndNotStored() async {
        let vm = viewModel(connect: { self.session(scopes: ["user:inference"]) })

        await vm.performConnect()

        XCTAssertNil(OAuthSessionStore.read(), "a session we will refuse to use must not be stored")
        let error = vm.lastError ?? ""
        XCTAssertTrue(error.contains("user:profile"),
                      "the message must name the missing permission, got: \(error)")
        vm.stop()
    }

    func testConnectWithProfileScopeStoresTheSession() async {
        let vm = viewModel(polling: .notSubscriber,
                           connect: { self.session(scopes: ["user:profile"]) })

        await vm.performConnect()

        XCTAssertEqual(OAuthSessionStore.read()?.accessToken, "at")
        XCTAssertNil(vm.lastError)
        vm.stop()
    }

    /// `lastError` had exactly one `nil` assignment, in the Keychain-adoption
    /// path, so a failed Connect stamped red text across the dropdown until
    /// relaunch — including over a subsequently healthy connected account.
    func testASuccessfulConnectClearsAPreviousConnectFailure() async {
        let calls = CallCount()
        let vm = viewModel(polling: .notSubscriber, connect: {
            calls.value += 1
            if calls.value == 1 { throw OAuthFlow.FlowError.cancelled }
            return self.session(scopes: ["user:profile"])
        })

        await vm.performConnect()
        XCTAssertNotNil(vm.lastError, "the first attempt failed and must say so")

        await vm.performConnect()
        XCTAssertNil(vm.lastError, "a completed connection must not keep the old failure on screen")
        vm.stop()
    }

    func testAFreshAttemptClearsTheErrorFromTheLastOne() async {
        let calls = CallCount()
        let vm = viewModel(connect: {
            calls.value += 1
            throw calls.value == 1
                ? OAuthFlow.FlowError.cancelled
                : OAuthFlow.FlowError.stateMismatch
        })

        await vm.performConnect()
        let first = vm.lastError
        XCTAssertNotNil(first)
        await vm.performConnect()
        XCTAssertNotEqual(vm.lastError, first, "each attempt reports its own outcome, not the last one's")
        vm.stop()
    }

    /// Re-entrancy is what made the stale-error scenario reachable: a user
    /// who abandoned one browser flow and completed a second had the first
    /// flow's 300-second timeout land on top of a healthy account.
    func testConnectRefusesToRunTwiceAtOnce() async {
        let calls = CallCount()
        let latch = Latch()
        let vm = viewModel(polling: .notSubscriber, connect: {
            calls.value += 1
            await latch.wait()
            return self.session(scopes: ["user:profile"])
        })

        let first = Task { await vm.performConnect() }
        // Spin until the first attempt is provably inside the flow, rather
        // than sleeping and hoping.
        var spins = 0
        while !vm.isConnecting, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(vm.isConnecting, "the first attempt never started")

        await vm.performConnect()
        XCTAssertEqual(calls.value, 1, "a second Connect while one is in flight must be ignored")

        latch.open()
        await first.value
        XCTAssertFalse(vm.isConnecting, "the guard must clear once the attempt finishes")
        vm.stop()
    }

    // MARK: - A dead grant is evicted, not rebuilt around

    /// `OAuthTokenProvider` drops a permanently-refused session from memory,
    /// but the Keychain item outlived it: the next launch read it back, saw
    /// `hasProfileScope`, and rebuilt a poller around a grant the server had
    /// already refused — with no way out but a manual `security
    /// delete-generic-password`.
    func testAnExpiredConnectionIsRemovedFromTheKeychain() throws {
        try OAuthSessionStore.write(session(scopes: ["user:profile"]))
        XCTAssertNotNil(OAuthSessionStore.read())

        let vm = viewModel()
        vm.applyAuthState(.connectionExpired)

        XCTAssertNil(OAuthSessionStore.read(),
                     "a dead grant must not be rebuilt around on the next launch")
    }

    func testAWorkingStateLeavesTheStoredSessionAlone() throws {
        try OAuthSessionStore.write(session(scopes: ["user:profile"]))

        let vm = viewModel()
        for state: AuthState in [.ok, .offline, .notSubscriber, .unknown, .invalidToken, .noToken] {
            vm.applyAuthState(state)
            XCTAssertNotNil(OAuthSessionStore.read(), "\(state) must not evict the session")
        }
    }

    func testReconnectFlagSetWhenNothingIsStored() {
        let vm = viewModel()
        vm.restartPollingForTest()
        XCTAssertEqual(vm.authState, .noToken)
        XCTAssertTrue(vm.needsReauthorization)

        pumpMainRunLoop()
        XCTAssertTrue(vm.needsReauthorization,
                      "no poller exists in this state, so nothing should flip the flag on a later run-loop turn")
    }
}
