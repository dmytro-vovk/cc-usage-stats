import Foundation

nonisolated struct WindowSnapshot: Codable, Equatable, Sendable {
    let usedPercentage: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// One surface's share of the weekly usage (`seven_day_breakdown.rows`),
/// e.g. Claude Code 93%. Shares of one window, so they sum to ~100.
nonisolated struct UsageShare: Codable, Equatable, Sendable {
    let key: String
    let name: String
    let percent: Double

    /// "Claude Code 93% · Chats 7%": API order, shares that *display* as 0%
    /// dropped (filtered after rounding, so 99.6/0.4 is not "100% · 0%");
    /// nil when nothing is left to show.
    static func caption(_ shares: [UsageShare]) -> String? {
        let parts = zip(shares, wholePercents(shares.map(\.percent)))
            .filter { $0.1 > 0 }
            .map { "\($0.0.name) \($0.1)%" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Largest-remainder rounding: floors each share, then hands the points
    /// lost to flooring to the largest fractions, so the integers keep the
    /// rounded total (50.5 / 49.5 → 51 / 49, not 51 / 50).
    static func wholePercents(_ values: [Double]) -> [Int] {
        let floors = values.map { Int($0.rounded(.down)) }
        let target = Int(values.reduce(0, +).rounded())
        var result = floors
        let order = values.indices.sorted {
            (values[$0] - Double(floors[$0])) > (values[$1] - Double(floors[$1]))
        }
        for i in order.prefix(max(0, target - floors.reduce(0, +))) { result[i] += 1 }
        return result
    }
}

/// The rate-limit windows cached for the menubar UI.
nonisolated struct RateLimitsSnapshot: Codable, Equatable, Sendable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?
    /// Per-model weekly windows, keyed by their wire key (e.g.
    /// "seven_day_fable"). Only populated by the /api/oauth/usage path;
    /// the response-header path cannot see these windows at all.
    let models: [String: WindowSnapshot]
    /// The weekly usage split by surface. Same source and same authority
    /// rule as `models`: only the usage endpoint reports it.
    let breakdown: [UsageShare]

    /// Whether `models` is a *complete statement* of the per-model weekly
    /// windows that exist for this account, or merely "this source has
    /// nothing to say about them".
    ///
    /// The two are not the same fact, and an empty dictionary cannot tell
    /// them apart. `GET /api/oauth/usage` returns every window it knows
    /// about in one body, so its answer — including an empty one — is
    /// authoritative and replaces whatever was cached. The response-header
    /// path physically cannot express a per-model limit, so its snapshots
    /// are `false`: they must neither define model windows nor keep an
    /// earlier source's alive. See `CacheStore.update`.
    let modelsAreAuthoritative: Bool

    /// Header-path shape: two windows, and no opinion about model windows.
    init(fiveHour: WindowSnapshot?, sevenDay: WindowSnapshot?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = [:]
        self.breakdown = []
        self.modelsAreAuthoritative = false
    }

    /// Usage-endpoint shape. Passing `models` at all is the claim that this
    /// source can see them, so `modelsAreAuthoritative` is true even when the
    /// dictionary is empty — "this account has no per-model window" is a real
    /// answer, and must clear a stale one.
    init(
        fiveHour: WindowSnapshot?,
        sevenDay: WindowSnapshot?,
        models: [String: WindowSnapshot],
        breakdown: [UsageShare] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
        self.breakdown = breakdown
        self.modelsAreAuthoritative = true
    }

    /// When a usage limit hit now lifts: the latest reset among the capped
    /// windows (every one has to reset). A per-model window is its own quota,
    /// so it counts only when `message` (Claude Code's "You've reached your
    /// Fable limit…") names that model. nil when nothing matching is capped.
    func limitResetsAt(now: Int64, message: String?) -> Int64? {
        let text = message?.lowercased() ?? ""
        let named = models.filter { key, _ in
            let model = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : key
            return !model.isEmpty && text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: model) + #"\b"#,
                                                options: .regularExpression) != nil
        }
        return ([fiveHour, sevenDay].compactMap { $0 } + Array(named.values))
            .filter { $0.usedPercentage >= 100 && $0.resetsAt > now }
            .map(\.resetsAt)
            .max()
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case models = "model_windows"
        case breakdown = "weekly_breakdown"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        let decodedModels = try c.decodeIfPresent(
            [String: WindowSnapshot].self, forKey: .models
        ) ?? [:]
        models = decodedModels
        breakdown = try c.decodeIfPresent([UsageShare].self, forKey: .breakdown) ?? []
        // Not persisted, and — as things stand — never read back: the flag
        // describes where a *freshly parsed* snapshot came from, and
        // `CacheStore.update` consults it only on `incoming`, which always
        // comes from a parser and never from disk. So this derivation is
        // inert today. It exists to keep a decoded value self-consistent
        // rather than arbitrarily `false`: model windows only ever reach the
        // file from an authoritative source, so a file that has them
        // represents an authoritative statement, and a read-modify-write
        // through `update` would otherwise clear the rows it just read back.
        // Pinned by `testDecodingDerivesAuthorityFromWhetherModelsWerePersisted`.
        modelsAreAuthoritative = !decodedModels.isEmpty
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
        if !models.isEmpty { try c.encode(models, forKey: .models) }
        if !breakdown.isEmpty { try c.encode(breakdown, forKey: .breakdown) }
    }
}
