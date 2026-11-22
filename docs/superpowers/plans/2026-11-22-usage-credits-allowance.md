# Usage-credits allowance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the remaining monthly usage-credit allowance in the dropdown (always, when credits are on) and in the menubar pill (while a Claude window is capped), and expose it via MCP `get_usage`.

**Architecture:** Parse `extra_usage` from `/api/oauth/usage` into a new `UsageCredits` value carried on `RateLimitsSnapshot` and persisted in `state.json`. One pure helper (`UsageCredits.band`) decides the pill's credit text/colour; `DisplayState` (single pill, capped 5h) and `PillLayout` (split pill, capped 7d/model) both use it. A new dropdown row and an MCP `usage_credits` object read the same value.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest. Tests: `scripts/test.sh [CCUsageStatsTests/<Class>/<test>]` from repo root. New files are picked up automatically (Xcode synchronized groups).

Spec: `docs/superpowers/specs/2026-11-22-usage-credits-allowance-design.md`.

## Global Constraints

- Amounts on the wire are minor units (cents); `monthly_limit: null` = unlimited.
- Credits shown only when `extra_usage.is_enabled == true`.
- Monthly limit only; the prepaid `spend.balance` is ignored.
- Reset = start of next calendar month, local time zone.
- Money: `NumberFormatter` `.currency` with the API currency (null → `USD`); cents shown only when the amount is < 100 units and not whole; limit always whole; rounding down.
- Header-path snapshots clear cached credits (same rule as `breakdown`).
- Pill: capped band shows credits only while credits are on and not exhausted; limited → OKLab ramp by used fraction; unlimited → amount spent, dimmed.
- Copy: "Usage credits", "$37.60 left", "$12.40 spent", "$12.40 of $50 used · resets Dec 1", "Unlimited · resets Dec 1".

---

### Task 1: `UsageCredits` value, money and reset formatting

**Files:**
- Create: `CCUsageStats/CCUsageStats/Core/UsageCredits.swift`
- Test: `CCUsageStats/CCUsageStatsTests/UsageCreditsTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageCredits: Codable, Equatable, Sendable { let limitCents: Int64?; let usedCents: Int64; let currency: String }`
  - `var isUnlimited: Bool`, `var remainingCents: Int64?`, `var usedFraction: Double?`, `var isExhausted: Bool`
  - `static func resetsAt(now: Int64, calendar: Calendar = .current) -> Int64`
  - `static func money(_ cents: Int64, currency: String, whole: Bool = false, locale: Locale = .current) -> String`
  - `func headline(locale: Locale = .current) -> String`
  - `func caption(now: Int64, calendar: Calendar = .current, locale: Locale = .current) -> String`
  - `struct CreditsBand: Equatable { let text: String; let colorFraction: Double?; let neutral: Bool }`
  - `func band(locale: Locale = .current) -> CreditsBand?`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify RED**

Run: `scripts/test.sh CCUsageStatsTests/UsageCreditsTests`
Expected: build failure, `cannot find 'UsageCredits' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The account's usage-credit allowance (`extra_usage` on
/// `/api/oauth/usage`), present only while credits are turned on. Amounts
/// are minor units (cents), as the endpoint reports them. Credits reset on
/// the 1st of each month — the endpoint gives no reset time; this is the
/// rule Claude Code's own `/usage` panel uses.
nonisolated struct UsageCredits: Codable, Equatable, Sendable {
    /// nil = unlimited.
    let limitCents: Int64?
    let usedCents: Int64
    let currency: String

    enum CodingKeys: String, CodingKey {
        case limitCents = "limit_cents"
        case usedCents = "used_cents"
        case currency
    }

    var isUnlimited: Bool { limitCents == nil }

    var remainingCents: Int64? { limitCents.map { max(0, $0 - usedCents) } }

    /// 0…1; a zero limit counts as fully used. nil when unlimited.
    var usedFraction: Double? {
        guard let limit = limitCents else { return nil }
        guard limit > 0 else { return 1 }
        return max(0, min(1, Double(usedCents) / Double(limit)))
    }

    var isExhausted: Bool { remainingCents == 0 }

    static func resetsAt(now: Int64, calendar: Calendar = .current) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        guard let month = calendar.dateInterval(of: .month, for: date) else { return now }
        return Int64(month.end.timeIntervalSince1970)
    }

    /// "$37.60", "$50", "$137": cents only below 100 units and only when
    /// not whole. Rounds down so "left" never overstates.
    static func money(_ cents: Int64, currency: String, whole: Bool = false, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency
        f.roundingMode = .down
        let showCents = !whole && abs(cents) < 10_000 && cents % 100 != 0
        f.minimumFractionDigits = showCents ? 2 : 0
        f.maximumFractionDigits = showCents ? 2 : 0
        let units = Double(cents) / 100
        return f.string(from: NSNumber(value: units)) ?? String(format: "%.2f %@", units, currency)
    }

    func headline(locale: Locale = .current) -> String {
        if let remaining = remainingCents {
            return "\(Self.money(remaining, currency: currency, locale: locale)) left"
        }
        return "\(Self.money(usedCents, currency: currency, locale: locale)) spent"
    }

    func caption(now: Int64, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let df = DateFormatter()
        df.locale = locale
        df.timeZone = calendar.timeZone
        df.setLocalizedDateFormatFromTemplate("MMMd")
        let reset = df.string(from: Date(timeIntervalSince1970: TimeInterval(Self.resetsAt(now: now, calendar: calendar))))
        guard let limit = limitCents else { return "Unlimited · resets \(reset)" }
        let used = Self.money(usedCents, currency: currency, locale: locale)
        let cap = Self.money(limit, currency: currency, whole: true, locale: locale)
        return "\(used) of \(cap) used · resets \(reset)"
    }

    /// What a capped pill band shows instead of its percentage or
    /// countdown. nil when credits are used up: the band keeps its
    /// ordinary capped look.
    func band(locale: Locale = .current) -> CreditsBand? {
        if isExhausted { return nil }
        if let remaining = remainingCents {
            return CreditsBand(text: Self.money(remaining, currency: currency, locale: locale),
                               colorFraction: usedFraction, neutral: false)
        }
        return CreditsBand(text: Self.money(usedCents, currency: currency, locale: locale),
                           colorFraction: nil, neutral: true)
    }
}

/// A capped pill band running on usage credits. `nonisolated` like
/// `UsageCredits`, which builds it (the target defaults to MainActor).
nonisolated struct CreditsBand: Equatable, Sendable {
    let text: String
    /// Place on the usage colour ramp; nil when `neutral`.
    let colorFraction: Double?
    /// Unlimited credits: nothing to budget, painted grey.
    let neutral: Bool
}
```

- [ ] **Step 4: Run to verify GREEN**

Run: `scripts/test.sh CCUsageStatsTests/UsageCreditsTests`
Expected: all 7 tests executed and passing. If a formatter string differs only by the platform's currency rendering (e.g. `€12.40` vs `€ 12.40`), fix the *test constant* to the real output, not the rules.

- [ ] **Step 5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Core/UsageCredits.swift CCUsageStats/CCUsageStatsTests/UsageCreditsTests.swift
git commit -m "feat: UsageCredits value with money, reset and band formatting"
```

---

### Task 2: Parse `extra_usage`, carry it on the snapshot, persist and merge

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Core/RateLimits.swift` (endpoint init, stored property, CodingKeys, decode/encode)
- Modify: `CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift:92-156` (`parseBody`)
- Modify: `CCUsageStats/CCUsageStats/Core/CacheStore.swift:65-103` (`update` merge + doc comment)
- Test: `CCUsageStats/CCUsageStatsTests/OAuthUsageTests.swift`, `CCUsageStats/CCUsageStatsTests/CacheStoreTests.swift`

**Interfaces:**
- Consumes: `UsageCredits` (Task 1).
- Produces: `RateLimitsSnapshot.credits: UsageCredits?`; the endpoint init gains `credits: UsageCredits? = nil` as its last parameter; persisted key `usage_credits`.

- [ ] **Step 1: Write the failing parser tests** (append to `OAuthUsageTests`)

```swift
    private func credits(_ extra: String) -> UsageCredits? {
        let json = """
        {"seven_day":{"utilization":24,"resets_at":"2026-10-05T09:59:59Z"},"extra_usage":\(extra)}
        """
        guard case let .success(snap) = OAuthUsage.parse(status: 200, body: body(json)) else { return nil }
        return snap.credits
    }

    func testExtraUsageEnabledWithLimit() {
        XCTAssertEqual(
            credits(#"{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"utilization":24.8,"currency":"EUR"}"#),
            UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "EUR")
        )
    }

    func testExtraUsageUnlimitedAndNullCurrency() {
        XCTAssertEqual(
            credits(#"{"is_enabled":true,"monthly_limit":null,"used_credits":1240,"currency":null}"#),
            UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD")
        )
    }

    func testExtraUsageNullUsedCountsAsZero() {
        XCTAssertEqual(
            credits(#"{"is_enabled":true,"monthly_limit":5000,"used_credits":null}"#),
            UsageCredits(limitCents: 5_000, usedCents: 0, currency: "USD")
        )
    }

    func testExtraUsageDisabledMissingOrMalformedIsNil() {
        XCTAssertNil(credits(#"{"is_enabled":false,"monthly_limit":5000,"used_credits":10}"#))
        XCTAssertNil(credits("null"))
        XCTAssertNil(credits(#"{"is_enabled":true,"monthly_limit":"lots","used_credits":10}"#))
        XCTAssertNil(credits(#"{"is_enabled":"yes","monthly_limit":5000,"used_credits":10}"#))
    }
```

- [ ] **Step 2: Write the failing cache tests** (append to `CacheStoreTests`; first read its opening ~30 lines and use its existing temp-file helper in place of `tempURL()`)

```swift
    func testUsageCreditsRoundTripAndHeaderPathClearsThem() throws {
        let url = tempURL()
        let credits = UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")
        let endpoint = RateLimitsSnapshot(
            fiveHour: nil, sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 9_999_999_999),
            models: [:], credits: credits
        )
        try CacheStore.update(at: url, with: endpoint, now: 100)
        XCTAssertEqual(try CacheStore.read(at: url)?.snapshot.credits, credits)

        // The response-header path cannot see credits: it must not keep
        // an unrefreshable dollar figure alive.
        let header = RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 9_999_999_999), sevenDay: nil)
        try CacheStore.update(at: url, with: header, now: 200)
        XCTAssertNil(try CacheStore.read(at: url)?.snapshot.credits)
    }

    func testAuthoritativeSnapshotWithoutCreditsClearsThem() throws {
        let url = tempURL()
        let week = WindowSnapshot(usedPercentage: 20, resetsAt: 9_999_999_999)
        try CacheStore.update(at: url, with: RateLimitsSnapshot(
            fiveHour: nil, sevenDay: week, models: [:],
            credits: UsageCredits(limitCents: 5_000, usedCents: 1, currency: "USD")
        ), now: 100)
        try CacheStore.update(at: url, with: RateLimitsSnapshot(fiveHour: nil, sevenDay: week, models: [:]), now: 200)
        XCTAssertNil(try CacheStore.read(at: url)?.snapshot.credits)
    }

    func testOldStateFileWithoutCreditsDecodes() throws {
        let json = #"{"seven_day":{"used_percentage":20,"resets_at":9999999999},"five_hour_absent":true}"#
        let snap = try JSONDecoder().decode(RateLimitsSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.credits)
    }
```

- [ ] **Step 3: Run to verify RED**

Run: `scripts/test.sh CCUsageStatsTests/OAuthUsageTests` and `scripts/test.sh CCUsageStatsTests/CacheStoreTests`
Expected: build failure (`extra argument 'credits'`, `has no member 'credits'`).

- [ ] **Step 4: Implement the snapshot field** (`RateLimits.swift`)

Add after `fiveHourIsAbsent`:

```swift
    /// The usage-credit allowance, when credits are on. Same source and
    /// authority rule as `breakdown`: only the usage endpoint reports it.
    let credits: UsageCredits?
```

- Header-path init: add `self.credits = nil`.
- Endpoint init: add parameter `credits: UsageCredits? = nil` after `fiveHourIsAbsent: Bool = false`, and `self.credits = credits`.
- CodingKeys: add `case credits = "usage_credits"`.
- `init(from:)`: `credits = try c.decodeIfPresent(UsageCredits.self, forKey: .credits)`.
- `encode(to:)`: `try c.encodeIfPresent(credits, forKey: .credits)`.

- [ ] **Step 5: Implement the parser** (`OAuthUsage.parseBody`, just before `return RateLimitsSnapshot(`)

```swift
        // Usage credits: only while turned on. Amounts are minor units;
        // a null limit is unlimited, a null spend is nothing spent yet.
        var credits: UsageCredits?
        if let extra = obj["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let limitValue = extra["monthly_limit"]
            let usedValue = extra["used_credits"]
            let limitOK = limitValue == nil || limitValue is NSNull || limitValue is NSNumber
            let usedOK = usedValue == nil || usedValue is NSNull || usedValue is NSNumber
            if limitOK, usedOK {
                credits = UsageCredits(
                    limitCents: (limitValue as? NSNumber).map { Int64($0.doubleValue.rounded()) },
                    usedCents: (usedValue as? NSNumber).map { Int64($0.doubleValue.rounded()) } ?? 0,
                    currency: (extra["currency"] as? String) ?? "USD"
                )
            }
        }
```

Pass `credits: credits` as the last argument of the `RateLimitsSnapshot(…)` return. (`JSONSerialization` gives `NSNumber` for bools; `"yes"` is a String and fails the `as? Bool`, which the test pins.)

- [ ] **Step 6: Implement the merge** (`CacheStore.update`)

```swift
            breakdown: incoming.modelsAreAuthoritative ? incoming.breakdown : [],
            fiveHourIsAbsent: fiveAbsent,
            credits: incoming.modelsAreAuthoritative ? incoming.credits : nil
```

Add to the `update` doc comment: "Usage credits follow the model-window rule: replaced by the endpoint, cleared by the header path."

- [ ] **Step 7: Run to verify GREEN**

Run: `scripts/test.sh CCUsageStatsTests/OAuthUsageTests`, then `scripts/test.sh CCUsageStatsTests/CacheStoreTests`
Expected: all pass, new tests listed as executed.

- [ ] **Step 8: Commit**

```bash
git add CCUsageStats/CCUsageStats/Core/RateLimits.swift CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift CCUsageStats/CCUsageStats/Core/CacheStore.swift CCUsageStats/CCUsageStatsTests/OAuthUsageTests.swift CCUsageStats/CCUsageStatsTests/CacheStoreTests.swift
git commit -m "feat: parse and cache the usage-credit allowance"
```

---

### Task 3: Capped single pill shows credits (`DisplayState` + tint)

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Core/DisplayState.swift`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift:185-194` (`tintNSColor`)
- Test: `CCUsageStats/CCUsageStatsTests/DisplayStateTests.swift`

**Interfaces:**
- Consumes: `RateLimitsSnapshot.credits`, `UsageCredits.band(locale:)`, `CreditsBand`.
- Produces: `DisplayState.creditsBand: CreditsBand?` (non-nil only when the lead window is capped and credits apply); `DisplayState.compute(now:cached:locale:)` with `locale: Locale = .current`.

- [ ] **Step 1: Write the failing tests** (append to `DisplayStateTests`)

```swift
    private func capped(_ credits: UsageCredits?) -> DisplayState {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 100, resetsAt: 7_300),
            sevenDay: .init(usedPercentage: 40, resetsAt: 900_000),
            models: [:], credits: credits
        ))
        return DisplayState.compute(now: 200, cached: cached, locale: Locale(identifier: "en_US"))
    }

    private var countdown: String { RelativeTime.formatHMS(seconds: 7_100) }

    func testCappedWithCreditsShowsRemaining() {
        let s = capped(UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD"))
        XCTAssertEqual(s.menuBarText, "$37.60")
        XCTAssertEqual(s.creditsBand?.colorFraction ?? -1, 0.248, accuracy: 0.0001)
        XCTAssertEqual(s.utilizationFraction, 1) // the gauge needle still says "capped"
    }

    func testCappedWithUnlimitedCreditsShowsSpentNeutral() {
        let s = capped(UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD"))
        XCTAssertEqual(s.menuBarText, "$12.40")
        XCTAssertEqual(s.creditsBand?.neutral, true)
    }

    func testCappedWithExhaustedOrNoCreditsKeepsCountdown() {
        XCTAssertEqual(capped(UsageCredits(limitCents: 5_000, usedCents: 5_000, currency: "USD")).menuBarText, countdown)
        XCTAssertNil(capped(nil).creditsBand)
        XCTAssertEqual(capped(nil).menuBarText, countdown)
    }

    func testUncappedIgnoresCredits() {
        let cached = CachedState(capturedAt: 100, snapshot: .init(
            fiveHour: .init(usedPercentage: 42, resetsAt: 7_300), sevenDay: nil, models: [:],
            credits: UsageCredits(limitCents: 5_000, usedCents: 1, currency: "USD")
        ))
        let s = DisplayState.compute(now: 200, cached: cached)
        XCTAssertEqual(s.menuBarText, "42%")
        XCTAssertNil(s.creditsBand)
    }
```

If `CachedState` has no `init(capturedAt:snapshot:)`, use whatever the existing `DisplayStateTests` use (they construct it the same way).

- [ ] **Step 2: Run to verify RED**

Run: `scripts/test.sh CCUsageStatsTests/DisplayStateTests`
Expected: build failure (`extra argument 'locale'`, `has no member 'creditsBand'`).

- [ ] **Step 3: Implement** (`DisplayState.swift`)

Add the property (a `var` with a default, so the memberwise init keeps working):

```swift
    /// The lead window is capped and usage credits are paying: the pill
    /// shows this instead of the countdown, painted by credits used.
    var creditsBand: CreditsBand? = nil
```

Change the signature to `static func compute(now: Int64, cached: CachedState?, locale: Locale = .current) -> DisplayState` and replace the text block and return with:

```swift
        let text: String
        var band: CreditsBand?
        if pct >= 100 {
            // Credits on and not used up: work continues on credits, so the
            // money left beats a countdown to a reset that no longer blocks.
            if let b = cached.snapshot.credits?.band(locale: locale) {
                band = b
                text = b.text
            } else {
                let secondsToReset = max(0, five.resetsAt - now)
                text = RelativeTime.formatHMS(seconds: secondsToReset)
            }
        } else {
            text = "\(pct)%"
        }

        return .init(
            menuBarText: text, utilizationFraction: fraction, isStale: stale,
            hasFiveHourData: cached.snapshot.fiveHour != nil, creditsBand: band
        )
```

Keep the existing comment above the capped branch, adding one line that credits take precedence.

- [ ] **Step 4: Tint** (`MenuBarContent.tintNSColor`, right after `if vm.displayState.isStale { … }`)

```swift
        if let band = vm.displayState.creditsBand {
            return band.neutral ? .secondaryLabelColor : UsageColor.nsColor(t: band.colorFraction ?? 1)
        }
```

- [ ] **Step 5: Run GREEN**

Run: `scripts/test.sh CCUsageStatsTests/DisplayStateTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add CCUsageStats/CCUsageStats/Core/DisplayState.swift CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift CCUsageStats/CCUsageStatsTests/DisplayStateTests.swift
git commit -m "feat: capped single pill shows remaining usage credits"
```

---

### Task 4: Capped split-pill bands show credits (`PillLayout`)

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Tray/PillLayout.swift:42-115`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift:43-51` (pass credits)
- Test: `CCUsageStats/CCUsageStatsTests/PillLayoutTests.swift`

**Interfaces:**
- Consumes: `UsageCredits.band(locale:)`, `CreditsBand`.
- Produces: `PillLayout.segments(five:seven:models:fiveText:authState:now:coloring:credits:locale:)` with `credits: UsageCredits? = nil, locale: Locale = .current`.

- [ ] **Step 1: Write the failing tests** (append to `PillLayoutTests`)

```swift
    private let us = Locale(identifier: "en_US")
    private let fifty = UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")

    private func withCredits(five: Double?, seven: Double?, models: [String: Double], credits: UsageCredits?) -> [PillSegment] {
        PillLayout.segments(
            five: five.map(w), seven: seven.map(w), models: models.mapValues(w),
            fiveText: "x", authState: .ok, now: 0, credits: credits, locale: us
        )
    }

    func testCappedModelBandShowsCredits() {
        let s = withCredits(five: 85, seven: 30, models: ["seven_day_fable": 100], credits: fifty)
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_fable")])
        XCTAssertEqual(s[1].text, "$37.60")
        XCTAssertEqual(s[1].paintFraction, 0.248, accuracy: 0.0001)
        XCTAssertFalse(s[1].dimmed)
        XCTAssertEqual(s[0].text, "x") // uncapped bands untouched
    }

    func testCappedWeeklyBandShowsCredits() {
        let s = withCredits(five: 90, seven: 100, models: [:], credits: fifty)
        XCTAssertEqual(s.last?.kind, .sevenDay)
        XCTAssertEqual(s.last?.text, "$37.60")
    }

    func testCappedLeadBandShowsCredits() {
        let s = withCredits(five: 100, seven: 30, models: [:], credits: fifty)
        XCTAssertEqual(s.map(\.text), ["$37.60"])
    }

    func testUnlimitedCreditsAreDimmedSpent() {
        let s = withCredits(five: 85, seven: 100, models: [:],
                            credits: UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD"))
        XCTAssertEqual(s.last?.text, "$12.40")
        XCTAssertEqual(s.last?.dimmed, true)
    }

    func testExhaustedOrAbsentCreditsLeaveBandsAlone() {
        let gone = UsageCredits(limitCents: 5_000, usedCents: 5_000, currency: "USD")
        XCTAssertEqual(withCredits(five: 85, seven: 100, models: [:], credits: gone).last?.text, "100%")
        XCTAssertEqual(withCredits(five: 85, seven: 100, models: [:], credits: nil).last?.text, "100%")
    }
```

- [ ] **Step 2: Run RED**

Run: `scripts/test.sh CCUsageStatsTests/PillLayoutTests`
Expected: build failure (`extra arguments 'credits', 'locale'`).

- [ ] **Step 3: Implement** (`PillLayout.segments`)

Add parameters `credits: UsageCredits? = nil, locale: Locale = .current` after `coloring: UsageColoring = .absolute`. At the top of the body:

```swift
        // A capped band running on usage credits shows the money left (or
        // spent, when unlimited) instead of its percentage or countdown.
        let creditsBand = credits?.band(locale: locale)
        func onCredits(_ s: PillSegment) -> PillSegment {
            guard s.fraction >= 1, let b = creditsBand else { return s }
            return PillSegment(kind: s.kind, fraction: s.fraction, text: b.text,
                               dimmed: b.neutral, colorFraction: b.colorFraction)
        }
```

Wrap the three segment constructions: `var result = [onCredits(PillSegment(…lead…))]`, `result.append(onCredits(.init(…sevenDay…)))`, `result.append(onCredits(.init(…model…)))`.

- [ ] **Step 4: Wire it** (`MenuBarContent`, the `PillLayout.segments(` call)

Add `credits: vm.cached?.snapshot.credits` after `coloring: vm.coloring`.

- [ ] **Step 5: Run GREEN**

Run: `scripts/test.sh CCUsageStatsTests/PillLayoutTests`, then `scripts/test.sh CCUsageStatsTests/PillComposerTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add CCUsageStats/CCUsageStats/Tray/PillLayout.swift CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift CCUsageStats/CCUsageStatsTests/PillLayoutTests.swift
git commit -m "feat: capped split-pill bands show usage credits"
```

---

### Task 5: Dropdown "Usage credits" row

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift` (`claudeWindows` ~line 384; new `CreditsSection` after `WindowSection` ~line 1045)

**Interfaces:**
- Consumes: `UsageCredits.headline()`, `.caption(now:)`, `.usedFraction`; `UsageColor.gradient(t:scheme:)`; `UsageBar(fraction:color:pace:overshootColor:)`; `View.wrapsFully()`.

Row text is covered by Task 1's `testRowText`; this task is view wiring, verified by build and the live check in Task 7.

- [ ] **Step 1: Add the view** (after `WindowSection`)

```swift
/// The usage-credit allowance, last in the Claude section while credits
/// are on. Limited: money left and a bar of credits used. Unlimited: money
/// spent, no bar.
private struct CreditsSection: View {
    let credits: UsageCredits
    let now: Int64
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fraction = credits.usedFraction
        let color = fraction.map { UsageColor.gradient(t: $0, scheme: colorScheme) }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage credits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(credits.headline())
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(color ?? .primary)
            }
            if let fraction, let color {
                UsageBar(fraction: fraction, color: color, pace: nil, overshootColor: color)
            }
            Text(credits.caption(now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapsFully()
        }
    }
}
```

Before compiling, read `UsageBar`'s declaration (`grep -n "struct UsageBar" -A12 CCUsageStats/CCUsageStats/Tray/*.swift`) and match its parameter names/optionality; if `color` there is a `Color` and `UsageColor.gradient` returns `Color`, the code stands as written.

- [ ] **Step 2: Place it** (`claudeWindows`, inside `if weeklyWindows`, after the model `ForEach`)

```swift
                if let credits = cached.snapshot.credits {
                    CreditsSection(credits: credits, now: now)
                }
```

Check the callers of `claudeWindows(sessionWindow:weeklyWindows:)`; the row must end up last in the Claude section in every layout that renders weekly windows.

- [ ] **Step 3: Build and run the full suite**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `exit=0`, executed count reported, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift
git commit -m "feat: Usage credits row in the dropdown"
```

---

### Task 6: MCP `usage_credits`

**Files:**
- Modify: `CCUsageStats/CCUsageStats/MCP/UsageReport.swift:31-95`
- Modify: `CCUsageStats/CCUsageStats/MCP/MCPServer.swift` (`toolDescription`)
- Test: `CCUsageStats/CCUsageStatsTests/UsageReportTests.swift`

**Interfaces:**
- Consumes: `RateLimitsSnapshot.credits`, `UsageCredits.resetsAt(now:calendar:)`, `.remainingCents`, `.usedFraction`, `.isUnlimited`.
- Produces: `claude.usage_credits` = `{unlimited, currency, limit, used, remaining, used_percent, resets_at, resets_at_iso, resets_at_local}`; `NSNull` for `limit`/`remaining`/`used_percent` when unlimited; key absent when credits are off.

- [ ] **Step 1: Write the failing tests** (append to `UsageReportTests`)

```swift
    private func state(credits: UsageCredits?) -> CachedState {
        CachedState(capturedAt: now - 60, snapshot: RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: now + 3_600),
            sevenDay: nil, models: [:], credits: credits
        ))
    }

    private func credits(_ r: [String: Any]) -> [String: Any]? {
        (r["claude"] as? [String: Any])?["usage_credits"] as? [String: Any]
    }

    func testUsageCreditsLimited() throws {
        let r = UsageReport.build(state: state(credits: UsageCredits(limitCents: 5_000, usedCents: 1_240, currency: "USD")),
                                  history: [], codex: nil, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
        let c = try XCTUnwrap(credits(r))
        XCTAssertEqual(c["unlimited"] as? Bool, false)
        XCTAssertEqual(c["currency"] as? String, "USD")
        XCTAssertEqual(c["limit"] as? Double, 50)
        XCTAssertEqual(c["used"] as? Double, 12.4)
        XCTAssertEqual(c["remaining"] as? Double, 37.6)
        XCTAssertEqual(c["used_percent"] as? Double ?? -1, 24.8, accuracy: 0.001)
        // now = 2033-05-18T03:33:20Z → resets 2033-06-01T00:00:00Z
        XCTAssertEqual(c["resets_at_iso"] as? String, "2033-06-01T00:00:00Z")
        XCTAssertNotNil(c["resets_at_local"] as? String)
    }

    func testUsageCreditsUnlimitedHasNulls() throws {
        let r = UsageReport.build(state: state(credits: UsageCredits(limitCents: nil, usedCents: 1_240, currency: "USD")),
                                  history: [], codex: nil, now: now)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
        let c = try XCTUnwrap(credits(r))
        XCTAssertEqual(c["unlimited"] as? Bool, true)
        XCTAssertTrue(c["limit"] is NSNull)
        XCTAssertTrue(c["remaining"] is NSNull)
        XCTAssertTrue(c["used_percent"] is NSNull)
        XCTAssertEqual(c["used"] as? Double, 12.4)
    }

    func testUsageCreditsAbsentWhenOff() {
        let r = UsageReport.build(state: state(credits: nil), history: [], codex: nil, now: now)
        XCTAssertNil(credits(r))
    }
```

- [ ] **Step 2: Run RED**

Run: `scripts/test.sh CCUsageStatsTests/UsageReportTests`
Expected: build failure (`extra argument 'credits'` resolves after Task 2, so here: the two positive tests FAIL on `XCTUnwrap`).

- [ ] **Step 3: Implement**

In `build`, change the call to `claudeSection(state, history: history, now: now, clock: clock, timeZone: timeZone)` and add `timeZone: TimeZone` to `claudeSection`'s signature. After the `weekly_breakdown` block:

```swift
        if let c = snap.credits {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let reset = UsageCredits.resetsAt(now: now, calendar: cal)
            func units(_ cents: Int64?) -> Any { cents.map { Double($0) / 100 } ?? NSNull() }
            out["usage_credits"] = [
                "unlimited": c.isUnlimited,
                "currency": c.currency,
                "limit": units(c.limitCents),
                "used": Double(c.usedCents) / 100,
                "remaining": units(c.remainingCents),
                "used_percent": c.usedFraction.map { $0 * 100 } ?? NSNull(),
                "resets_at": reset,
                "resets_at_iso": clock.iso(reset),
                "resets_at_local": clock.local(reset),
            ] as [String: Any]
        }
```

`used_percent` uses the clamped fraction, so overspend reports 100.

- [ ] **Step 4: Tool description** (`MCPServer.toolDescription`)

After the sentence that lists the per-window fields, insert: `When usage credits are on, claude.usage_credits gives the monthly credit allowance (limit, used and remaining in currency units; null limit = unlimited; resets on the 1st): a capped window with credits remaining does not block work. \` (keep the file's line-continuation style).

- [ ] **Step 5: Run GREEN**

Run: `scripts/test.sh CCUsageStatsTests/UsageReportTests`; then `grep -ln "toolDescription" CCUsageStats/CCUsageStatsTests` and run those classes, updating a pinned string if one exists.
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add CCUsageStats/CCUsageStats/MCP/UsageReport.swift CCUsageStats/CCUsageStats/MCP/MCPServer.swift CCUsageStats/CCUsageStatsTests/UsageReportTests.swift
git commit -m "feat: get_usage reports the usage-credit allowance"
```

---

### Task 7: Docs, full suite, review, live check

**Files:**
- Modify: `README.md` (Menubar, Dropdown, MCP sections); `NOTES.md` for anything observed-not-fixed.

- [ ] **Step 1: README** — Menubar: one bullet that a capped band shows remaining usage credits (or the amount spent, when unlimited) while credits are on. Dropdown: one bullet for the "Usage credits" row. MCP: mention `usage_credits`. Only what changed.
- [ ] **Step 2: Full suite** — `scripts/test.sh > /tmp/ccus-test.log 2>&1; echo "exit=$?"; grep -E "Executed [0-9]+ tests" /tmp/ccus-test.log | tail -1`. Require `exit=0`, executed count higher than on main, 0 failures.
- [ ] **Step 3: Review** — MCP wire format changed, so Fable + Codex + Gemini in parallel with the scoped review template from the global CLAUDE.md, scope line "Show usage-credits allowance: parse extra_usage, dropdown row, capped pill band, MCP usage_credits". Adjudicate; fix P0/P1; re-review fix commits; re-run suite.
- [ ] **Step 4: Live check** — `scripts/install-dev.sh`; read the poll log (`/usr/bin/log show --last 5m --predicate 'subsystem == "dev.dv.ccusagestats" AND category == "usage"'`) to confirm the key set; open the dropdown and see the row if the account has credits on. If credits are off on this account, say so and rely on a fixture-fed render (`TEST_RUNNER_CCUS_RENDER_SHOTS` path) or report the gap. MCP: call `get_usage` and check `usage_credits` presence matches the account.
- [ ] **Step 5: Commit docs**

```bash
git add README.md
git commit -m "docs: usage-credits row, capped pill and MCP field"
```
