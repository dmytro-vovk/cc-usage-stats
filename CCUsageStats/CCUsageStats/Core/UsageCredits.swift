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
