import Combine
import XCTest
@testable import CCUsageStats

/// Coverage for the recovery-hint lifecycle and the token states around it —
/// the wiring that had none, and where a stale message under a healthy readout
/// came from in the first place.
///
/// `start()` is deliberately never called: it opens file watchers, timers and a
/// status poller, and no-ops under test anyway. Everything here drives the
/// state machine directly, with an injected probe and API client so no network
/// call or real Keychain read happens.
@MainActor
final class MenuViewModelTests: XCTestCase {
    private let deadline = Date(timeIntervalSince1970: 1_785_000_000)

    override func setUpWithError() throws {
        try? TokenStore.delete()
    }
    override func tearDownWithError() throws {
        try? TokenStore.delete()
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

    func testReconnectFlagSetWhenOnlyAPastedTokenExists() throws {
        try TokenStore.write("sk-ant-oat01-stub")
        let vm = viewModel(polling: .success(
            RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 2),
                               sevenDay: nil)
        ))
        vm.restartPollingForTest()
        XCTAssertTrue(vm.needsReauthorization,
                      "a header-only user must be told the model meter needs connecting")
    }

    func testReconnectFlagSetWhenNothingIsStored() {
        let vm = viewModel()
        vm.restartPollingForTest()
        XCTAssertEqual(vm.authState, .noToken)
        XCTAssertTrue(vm.needsReauthorization)
    }
}
