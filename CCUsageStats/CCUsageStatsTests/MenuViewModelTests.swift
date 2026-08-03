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
/// itself reads `OAuthSessionStore` and, when a scoped session is present,
/// builds a real `OAuthUsageClient` that talks to api.anthropic.com — the
/// injected `apiFactory` stub only covers the header-fallback path. No test
/// today stores an OAuth session, so in practice none of that fires, but
/// `setUp`/`tearDown` clear `OAuthSessionStore` regardless so a future test
/// that does store one can't leak into its neighbors or start a live network
/// call from this suite.
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
        MenuViewModel { _ in StubAPI(result: result) }
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
