import XCTest
@testable import CCUsageStats

/// `Verdict`'s synthesized `Equatable` conformance is main-actor isolated (the
/// target compiles with main-actor default isolation), so the comparisons below
/// have to run there too. Same treatment as `AuthStateTests`.
@MainActor
final class TokenDurabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25 18:40 UTC

    private func inHours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }

    // MARK: - Classification

    /// A hand-pasted `claude setup-token` value has no expiry we can observe.
    /// Treating that as durable is the whole reason manual pastes stay quiet.
    func testAbsentExpiryIsDurable() {
        XCTAssertEqual(TokenDurability.classify(expiresAt: nil, now: now), .durable)
    }

    func testFutureExpiryIsExpiring() {
        XCTAssertEqual(
            TokenDurability.classify(expiresAt: inHours(8), now: now),
            .expiring(inHours(8))
        )
    }

    func testPastExpiryIsExpired() {
        XCTAssertEqual(
            TokenDurability.classify(expiresAt: inHours(-1), now: now),
            .expired(inHours(-1))
        )
    }

    /// Exactly at the deadline counts as expired, matching the probe's own
    /// `expiry <= now` rejection so the two can't disagree by a second.
    func testExpiryExactlyNowIsExpired() {
        XCTAssertEqual(TokenDurability.classify(expiresAt: now, now: now), .expired(now))
    }

    // MARK: - Import notice

    func testNoImportNoticeForDurableToken() {
        XCTAssertNil(TokenDurability.importNotice(expiresAt: nil, now: now))
    }

    /// The observed real-world case: `claude setup-token` writes an 8-hour
    /// access token into the Keychain, so every import must be explained.
    func testImportNoticeForObservedEightHourToken() throws {
        let notice = try XCTUnwrap(TokenDurability.importNotice(expiresAt: inHours(8), now: now))
        XCTAssertTrue(notice.contains("8h 0m"), notice)
        XCTAssertTrue(notice.contains("claude setup-token"), notice)
    }

    func testNoImportNoticeBeyondTheWarningWindow() {
        XCTAssertNil(TokenDurability.importNotice(expiresAt: inHours(25), now: now))
    }

    func testImportNoticeJustInsideTheWarningWindow() {
        XCTAssertNotNil(TokenDurability.importNotice(expiresAt: inHours(23), now: now))
    }

    func testImportNoticeForAlreadyExpiredToken() {
        let notice = TokenDurability.importNotice(expiresAt: inHours(-1), now: now)
        XCTAssertEqual(notice?.contains("already expired"), true)
    }

    // MARK: - Dropdown caption

    func testNoDropdownCaptionForDurableToken() {
        XCTAssertNil(TokenDurability.dropdownCaption(expiresAt: nil, now: now))
    }

    /// A fresh 8-hour import must not park a warning in the menu all day.
    func testNoDropdownCaptionWhileExpiryIsHoursAway() {
        XCTAssertNil(TokenDurability.dropdownCaption(expiresAt: inHours(8), now: now))
    }

    func testDropdownCaptionInsideTheFinalHour() {
        let caption = TokenDurability.dropdownCaption(expiresAt: now.addingTimeInterval(43 * 60), now: now)
        XCTAssertEqual(caption, "Token expires in 43m.")
    }

    func testDropdownCaptionForExpiredToken() {
        XCTAssertEqual(
            TokenDurability.dropdownCaption(expiresAt: inHours(-2), now: now),
            "Token expired — re-import or paste a new one."
        )
    }

    /// Boundary: exactly one hour out is outside the hint window.
    func testNoDropdownCaptionExactlyAtTheHintWindow() {
        XCTAssertNil(TokenDurability.dropdownCaption(expiresAt: inHours(1), now: now))
    }
}
