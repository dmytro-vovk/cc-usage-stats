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
            TokenRecovery.decide(rejected: "sk-ant-oat01-stale", found: .found(candidate)),
            .adopted(candidate)
        )
    }

    /// The case that makes the button honest: Claude Code hasn't rotated
    /// anything, so re-importing would walk straight back into the same 401.
    func testReportsSameTokenWhenKeychainStillHoldsTheRejectedOne() {
        XCTAssertEqual(
            TokenRecovery.decide(
                rejected: "sk-ant-oat01-stale",
                found: .found(imported("sk-ant-oat01-stale", expiresAt: expiry))
            ),
            .sameTokenRejected
        )
    }

    func testReportsNoneWhenKeychainYieldsNothing() {
        XCTAssertEqual(
            TokenRecovery.decide(rejected: "sk-ant-oat01-stale", found: .noEntries),
            .noneAvailable(.noEntries)
        )
    }

    /// No stored token at all (fresh install, or the item was deleted): any
    /// candidate is an improvement.
    func testAdoptsWhenThereIsNoRejectedTokenToCompareAgainst() {
        let candidate = imported("sk-ant-oat01-fresh")
        XCTAssertEqual(TokenRecovery.decide(rejected: nil, found: .found(candidate)), .adopted(candidate))
    }

    func testNoRejectedTokenAndNoCandidateIsNoneAvailable() {
        XCTAssertEqual(TokenRecovery.decide(rejected: nil, found: .noEntries), .noneAvailable(.noEntries))
    }

    /// Same token string but a later deadline still counts as "same" — the
    /// string is what the API rejects, so a refreshed expiry can't fix a 401.
    func testSameTokenWithDifferentExpiryIsStillSameTokenRejected() {
        XCTAssertEqual(
            TokenRecovery.decide(
                rejected: "sk-ant-oat01-stale",
                found: .found(imported("sk-ant-oat01-stale", expiresAt: expiry.addingTimeInterval(86_400)))
            ),
            .sameTokenRejected
        )
    }

    /// Every miss reason survives the decision intact — the whole point of
    /// carrying it is that the message downstream can name it.
    func testMissReasonIsCarriedThrough() {
        for probe: ClaudeCodeKeychainProbe.Outcome in [.expired(expiry), .accessDenied, .noClaudeToken, .noEntries] {
            XCTAssertEqual(
                TokenRecovery.decide(rejected: "sk-ant-oat01-stale", found: probe),
                .noneAvailable(probe)
            )
        }
    }
}

@MainActor
final class RecoveryCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    func testAdoptedNeedsNoMessage() {
        let outcome = TokenRecovery.Outcome.adopted(
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-fresh", expiresAt: nil)
        )
        XCTAssertNil(RecoveryCopy.message(for: outcome, now: now))
    }

    /// The message this work exists for: the real-world case was an 8-hour
    /// token that lapsed overnight, reported as a flat "no usable token".
    func testExpiredMessageQuotesHowLongAgoItLapsed() {
        let message = RecoveryCopy.message(
            for: .noneAvailable(.expired(now.addingTimeInterval(-(13 * 3600 + 28 * 60)))),
            now: now
        )
        XCTAssertEqual(
            message,
            "Claude Code's token expired 13h 28m ago, and no fresher one was found. "
                + "Use Claude Code once to rotate it, or run `claude setup-token` and paste the value it "
                + "prints — that one is long-lived."
        )
    }

    /// The message must not assert what the CLI did — a rotated token in a shape
    /// this build can't parse also lands in `.expired`.
    func testExpiredMessageDoesNotClaimTheCLINeverRefreshed() {
        let message = RecoveryCopy.message(for: .expired(now.addingTimeInterval(-3600)), now: now)
        XCTAssertFalse(message.contains("hasn't refreshed"), message)
        XCTAssertTrue(message.contains("no fresher one was found"), message)
    }

    /// A deadline in the future can't happen through `classify`, but the copy
    /// must not render "expired -0h ago" if it ever does.
    func testExpiredMessageClampsAFutureDeadline() {
        let message = RecoveryCopy.message(for: .expired(now.addingTimeInterval(3600)), now: now)
        XCTAssertTrue(message.contains("expired 0s ago"), message)
    }

    func testDeniedMessageTellsTheUserToAllow() {
        let message = RecoveryCopy.message(for: .accessDenied, now: now)
        XCTAssertTrue(message.contains("denied access"), message)
        XCTAssertTrue(message.contains("Allow"), message)
    }

    /// `.noClaudeToken` covers MCP-only entries, an API key in the token slot,
    /// and unrecognized shapes — so the copy must not single one of them out.
    func testMCPOnlyMessageNamesEveryCauseItCovers() {
        let message = RecoveryCopy.message(for: .noClaudeToken, now: now)
        XCTAssertTrue(message.contains("MCP logins"), message)
        XCTAssertTrue(message.contains("API key"), message)
        XCTAssertFalse(message.contains("MCP logins only"), message)
    }

    func testNoEntriesMessageDoesNotClaimSomethingExpired() {
        let message = RecoveryCopy.message(for: .noEntries, now: now)
        XCTAssertTrue(message.contains("No Claude Code credentials"), message)
        XCTAssertFalse(message.contains("expired"), message)
    }

    /// Distinct causes must not produce interchangeable text — that was the
    /// original defect.
    func testEveryMissReadsDifferently() {
        let messages: [String] = [
            RecoveryCopy.message(for: .expired(now.addingTimeInterval(-3600)), now: now),
            RecoveryCopy.message(for: .accessDenied, now: now),
            RecoveryCopy.message(for: .noClaudeToken, now: now),
            RecoveryCopy.message(for: .noEntries, now: now),
        ]
        XCTAssertEqual(Set(messages).count, messages.count)
    }
}
