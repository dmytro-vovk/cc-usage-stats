import XCTest
@testable import CCUsageStats

final class ReconnectPromptTests: XCTestCase {
    func testNeverConnectedIsInvitedToConnect() {
        let prompt = ReconnectPrompt.decide(needsReauthorization: true, authState: .ok, source: .pastedToken)
        XCTAssertEqual(prompt, .connect)
        XCTAssertEqual(prompt?.message, "Connect your account to see per-model weekly usage.")
        XCTAssertEqual(prompt?.buttonLabel, "Connect Claude account")
    }

    /// The session was there and the server refused it; the pasted token is
    /// carrying the app. Saying "connect your account" here reads as if the
    /// per-model rows had simply vanished.
    func testRefusedSessionOnFallbackSaysTheConnectionExpired() {
        let prompt = ReconnectPrompt.decide(needsReauthorization: true, authState: .ok, source: .connectedAccount)
        XCTAssertEqual(prompt, .reconnect)
        XCTAssertEqual(
            prompt?.message,
            "Claude account connection expired. Reconnect to see per-model weekly usage.")
        XCTAssertEqual(prompt?.buttonLabel, "Reconnect Claude account")
    }

    func testNoPromptWhileTheSessionWorks() {
        XCTAssertNil(ReconnectPrompt.decide(needsReauthorization: false, authState: .ok, source: .connectedAccount))
    }

    /// Those states have their own row; the prompt under it is noise.
    func testNoPromptWithoutAWorkingToken() {
        for state in AuthState.allCases where state.lacksWorkingToken {
            for source in [MenuViewModel.ClaudeSource.connectedAccount, .pastedToken, .none] {
                XCTAssertNil(
                    ReconnectPrompt.decide(needsReauthorization: true, authState: state, source: source),
                    "\(state) / \(source)")
            }
        }
    }

    /// Offline or no-subscription keeps the prompt, as before.
    func testPromptSurvivesStatesThatStillHaveAToken() {
        for state in AuthState.allCases where !state.lacksWorkingToken {
            XCTAssertEqual(
                ReconnectPrompt.decide(needsReauthorization: true, authState: state, source: .connectedAccount),
                .reconnect, "\(state)")
        }
    }
}
