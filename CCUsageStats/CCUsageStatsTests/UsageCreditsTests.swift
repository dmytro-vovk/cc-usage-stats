import XCTest
@testable import CCUsageStats

final class UsageCreditsTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let limited = UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")
    private let unlimited = UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD")
    /// 2026-11-22T12:00:00Z
    private let nov22: Int64 = 1_795_348_800

    func testDerivedValues() {
        XCTAssertEqual(limited.remainingCents, 3_760)
        XCTAssertEqual(limited.usedFraction ?? -1, 0.248, accuracy: 0.0001)
        XCTAssertFalse(limited.isExhausted)
        XCTAssertNil(unlimited.remainingCents)
        XCTAssertNil(unlimited.usedFraction)
        XCTAssertFalse(unlimited.isExhausted)
    }

    func testOverspendClampsAndIsExhausted() {
        let over = UsageCredits(limitCents: 5_000, usedCents: 5_100, currency: "USD")
        XCTAssertEqual(over.remainingCents, 0)
        XCTAssertEqual(over.usedFraction, 1)
        XCTAssertTrue(over.isExhausted)
    }

    func testZeroLimitIsExhaustedNotDivideByZero() {
        let zero = UsageCredits(limitCents: 0, usedCents: 0, currency: "USD")
        XCTAssertEqual(zero.usedFraction, 1)
        XCTAssertTrue(zero.isExhausted)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(UsageCredits.money(3_760, currency: "USD", locale: us), "$37.60")
        XCTAssertEqual(UsageCredits.money(5_000, currency: "USD", locale: us), "$50")
        XCTAssertEqual(UsageCredits.money(0, currency: "USD", locale: us), "$0")
        XCTAssertEqual(UsageCredits.money(13_799, currency: "USD", locale: us), "$137")
        XCTAssertEqual(UsageCredits.money(5_050, currency: "USD", whole: true, locale: us), "$50")
        XCTAssertEqual(UsageCredits.money(1_240, currency: "EUR", locale: us), "€12.40")
    }

    func testResetIsStartOfNextMonth() {
        XCTAssertEqual(UsageCredits.resetsAt(now: nov22, calendar: utc), 1_796_083_200) // 2026-12-01Z
        // December rolls into January of the next year.
        XCTAssertEqual(UsageCredits.resetsAt(now: 1_797_940_800, calendar: utc), 1_798_761_600) // 2026-12-22 → 2027-01-01
    }

    func testRowText() {
        XCTAssertEqual(limited.headline(locale: us), "$37.60 left")
        XCTAssertEqual(limited.caption(now: nov22, calendar: utc, locale: us), "$12.40 of $50 used · resets Dec 1")
        XCTAssertEqual(unlimited.headline(locale: us), "$12.40 spent")
        XCTAssertEqual(unlimited.caption(now: nov22, calendar: utc, locale: us), "Unlimited · resets Dec 1")
    }

    func testBand() {
        XCTAssertEqual(limited.band(locale: us)?.text, "$37.60")
        XCTAssertEqual(limited.band(locale: us)?.colorFraction ?? -1, 0.248, accuracy: 0.0001)
        XCTAssertEqual(limited.band(locale: us)?.neutral, false)
        XCTAssertEqual(unlimited.band(locale: us), CreditsBand(text: "$12.40", colorFraction: nil, neutral: true))
        XCTAssertNil(UsageCredits(limitCents: 5_000, usedCents: 5_000, currency: "USD").band(locale: us))
    }
}
