import Foundation

struct DisplayState: Equatable {
    let menuBarText: String
    /// 0..1 utilization fraction for the primary window (5-hour, or weekly
    /// when the account has none), or nil when no data.
    /// Drives the gradient color applied to the menubar icon + text.
    let utilizationFraction: Double?
    let isStale: Bool
    let hasFiveHourData: Bool
    /// The lead window is capped and usage credits are paying: the pill
    /// shows this instead of the countdown, painted by credits used.
    var creditsBand: CreditsBand? = nil

    static let staleThresholdSeconds: Int64 = 30 * 60

    static func compute(now: Int64, cached: CachedState?, locale: Locale = .current) -> DisplayState {
        guard let cached, let five = cached.snapshot.primaryWindow?.window else {
            return .init(menuBarText: "—", utilizationFraction: nil, isStale: false, hasFiveHourData: false)
        }
        let pct = Int(five.usedPercentage.rounded())
        let fraction = max(0.0, min(1.0, five.usedPercentage / 100.0))
        // The age of the reading shown, not of the file: a window only
        // carried over from disk is as old as when it was last reported.
        let stale = (now - cached.primaryCapturedAt) > staleThresholdSeconds

        // At cap, swap the percentage for a live countdown to reset. The
        // gauge icon's 100%-needle position + red gradient still conveys
        // "capped"; the text becomes the more useful "2h 14m" instead of
        // a stuck "100%". Credits take precedence over the countdown.
        let text: String
        var band: CreditsBand?
        if pct >= 100 {
            // Credits on and not used up: work continues on credits, so the
            // money left beats a countdown to a reset that no longer blocks.
            if UsageCredits.isCapped(five, now: now), let b = cached.snapshot.credits?.band(locale: locale) {
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
    }
}
