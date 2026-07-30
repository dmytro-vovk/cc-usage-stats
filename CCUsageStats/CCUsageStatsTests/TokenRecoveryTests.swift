import XCTest
@testable import CCUsageStats

/// `Outcome`'s synthesized `Equatable` conformance is main-actor isolated, so
/// the comparisons below have to run there too. Same treatment as `AuthStateTests`.
@MainActor
final class TokenRecoveryTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_785_028_800)

    private func imported(_ token: String, expiresAt: Date? = nil) -> ClaudeCodeKeychainProbe.ImportedToken {
        ClaudeCodeKeychainProbe.ImportedToken(token: token, expiresAt: expiresAt)
    }

    func testAdoptsFresherTokenFromKeychain() {
        let candidate = imported("sk-ant-oat01-fresh", expiresAt: expiry)
        XCTAssertEqual(
            TokenRecovery.decide(rejected: "sk-ant-oat01-stale", candidate: candidate),
            .adopted(candidate)
        )
    }

    /// The case that makes the button honest: Claude Code hasn't rotated
    /// anything, so re-importing would walk straight back into the same 401.
    func testReportsSameTokenWhenKeychainStillHoldsTheRejectedOne() {
        XCTAssertEqual(
            TokenRecovery.decide(
                rejected: "sk-ant-oat01-stale",
                candidate: imported("sk-ant-oat01-stale", expiresAt: expiry)
            ),
            .sameTokenRejected
        )
    }

    func testReportsNoneWhenKeychainYieldsNothing() {
        XCTAssertEqual(
            TokenRecovery.decide(rejected: "sk-ant-oat01-stale", candidate: nil),
            .noneAvailable
        )
    }

    /// No stored token at all (fresh install, or the item was deleted): any
    /// candidate is an improvement.
    func testAdoptsWhenThereIsNoRejectedTokenToCompareAgainst() {
        let candidate = imported("sk-ant-oat01-fresh")
        XCTAssertEqual(TokenRecovery.decide(rejected: nil, candidate: candidate), .adopted(candidate))
    }

    func testNoRejectedTokenAndNoCandidateIsNoneAvailable() {
        XCTAssertEqual(TokenRecovery.decide(rejected: nil, candidate: nil), .noneAvailable)
    }

    /// Same token string but a later deadline still counts as "same" — the
    /// string is what the API rejects, so a refreshed expiry can't fix a 401.
    func testSameTokenWithDifferentExpiryIsStillSameTokenRejected() {
        XCTAssertEqual(
            TokenRecovery.decide(
                rejected: "sk-ant-oat01-stale",
                candidate: imported("sk-ant-oat01-stale", expiresAt: expiry.addingTimeInterval(86_400))
            ),
            .sameTokenRejected
        )
    }
}
