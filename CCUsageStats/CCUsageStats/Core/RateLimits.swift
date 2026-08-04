import Foundation

struct WindowSnapshot: Codable, Equatable {
    let usedPercentage: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// The rate-limit windows cached for the menubar UI.
struct RateLimitsSnapshot: Codable, Equatable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?
    /// Per-model weekly windows, keyed by their wire key (e.g.
    /// "seven_day_fable"). Only populated by the /api/oauth/usage path;
    /// the response-header path cannot see these windows at all.
    let models: [String: WindowSnapshot]

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
        self.modelsAreAuthoritative = false
    }

    /// Usage-endpoint shape. Passing `models` at all is the claim that this
    /// source can see them, so `modelsAreAuthoritative` is true even when the
    /// dictionary is empty — "this account has no per-model window" is a real
    /// answer, and must clear a stale one.
    init(
        fiveHour: WindowSnapshot?,
        sevenDay: WindowSnapshot?,
        models: [String: WindowSnapshot]
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
        self.modelsAreAuthoritative = true
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case models = "model_windows"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        let decodedModels = try c.decodeIfPresent(
            [String: WindowSnapshot].self, forKey: .models
        ) ?? [:]
        models = decodedModels
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
    }
}
