import Foundation

struct CachedState: Codable, Equatable {
    /// When the file was last written by a successful poll.
    let capturedAt: Int64
    let snapshot: RateLimitsSnapshot
    /// When the 5-hour / 7-day window was last actually *reported*, keyed
    /// `five_hour` / `seven_day`. A poll that carries only one of them keeps
    /// the other from disk; without this its reading would pass as being as
    /// fresh as the file. Absent for a window read at `capturedAt`, and in
    /// files written before this existed.
    let windowCapturedAt: [String: Int64]

    static let fiveHourKey = "five_hour"
    static let sevenDayKey = "seven_day"

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case windowCapturedAt = "window_captured_at"
    }

    init(capturedAt: Int64, snapshot: RateLimitsSnapshot, windowCapturedAt: [String: Int64] = [:]) {
        self.capturedAt = capturedAt
        self.snapshot = snapshot
        self.windowCapturedAt = windowCapturedAt.filter { $0.value != capturedAt }
    }

    /// When the window `key` was last reported (never later than the file).
    func capturedAt(of key: String) -> Int64 {
        min(windowCapturedAt[key] ?? capturedAt, capturedAt)
    }

    /// Capture time of the window the menubar leads with.
    var primaryCapturedAt: Int64 {
        capturedAt(of: snapshot.fiveHour != nil ? Self.fiveHourKey : Self.sevenDayKey)
    }

    // The snapshot's own window keys live in the *same* flat container as
    // `captured_at`, so both halves are read and written through one
    // decoder/encoder rather than being spelled out twice. This file used to
    // carry its own copy of the window coding keys, which is how the two
    // could drift apart.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        snapshot = try RateLimitsSnapshot(from: decoder)
        windowCapturedAt = (try? c.decodeIfPresent([String: Int64].self, forKey: .windowCapturedAt)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAt, forKey: .capturedAt)
        if !windowCapturedAt.isEmpty { try c.encode(windowCapturedAt, forKey: .windowCapturedAt) }
        try snapshot.encode(to: encoder)
    }
}

enum CacheStore {
    /// Returns nil for both "file absent" and "file present but unparseable".
    static func read(at url: URL) throws -> CachedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedState.self, from: data)
    }

    /// Merges `incoming` into existing state and atomically writes.
    /// Absent fields in `incoming` (nil five_hour or nil seven_day) preserve
    /// whatever is on disk for that field — except a 5h window the source
    /// says does not exist (`fiveHourIsAbsent`), which is cleared.
    ///
    /// Model windows do **not** work that way, and deliberately so. Only a
    /// source that can see them may define them:
    ///
    ///   - `modelsAreAuthoritative` — the whole set is replaced. A key the
    ///     endpoint stopped reporting is gone, not merely unmentioned.
    ///   - otherwise (the response-header path) — the set is *cleared*. That
    ///     source cannot express a per-model limit, so it can neither add one
    ///     nor vouch for one somebody else added.
    ///
    /// This used to be a per-key merge with no source distinction, and
    /// `captured_at` is snapshot-wide: a connected user whose grant later
    /// died fell back to the header path, and every subsequent header poll
    /// re-stamped `captured_at` over a frozen "Opus weekly · 83%" that
    /// nothing could refresh. The dropdown rendered it at full freshness,
    /// directly above "Last updated 4s ago", while simultaneously offering to
    /// connect the account that used to produce it. Do not reinstate per-key
    /// preservation: an unrefreshable number presented as current is worse
    /// than no number.
    static func update(at url: URL, with incoming: RateLimitsSnapshot, now: Int64) throws {
        let existingState = try read(at: url)
        let existing = existingState?.snapshot
        let five = incoming.fiveHourIsAbsent ? nil : (incoming.fiveHour ?? existing?.fiveHour)
        // "No 5-hour limit" is remembered until a 5-hour window is seen: a
        // poll with no opinion (the gap between two windows) neither sets
        // nor clears it.
        let fiveAbsent = five == nil
            && (incoming.fiveHourIsAbsent || (incoming.fiveHour == nil && existing?.fiveHourIsAbsent == true))
        let merged = RateLimitsSnapshot(
            fiveHour: five,
            sevenDay: incoming.sevenDay ?? existing?.sevenDay,
            models: incoming.modelsAreAuthoritative ? incoming.models : [:],
            breakdown: incoming.modelsAreAuthoritative ? incoming.breakdown : [],
            fiveHourIsAbsent: fiveAbsent
        )
        // A window this poll did not report keeps the time it was last seen.
        var stamps: [String: Int64] = [:]
        if incoming.fiveHour == nil, merged.fiveHour != nil, let existingState {
            stamps[CachedState.fiveHourKey] = existingState.capturedAt(of: CachedState.fiveHourKey)
        }
        if incoming.sevenDay == nil, merged.sevenDay != nil, let existingState {
            stamps[CachedState.sevenDayKey] = existingState.capturedAt(of: CachedState.sevenDayKey)
        }
        let state = CachedState(capturedAt: now, snapshot: merged, windowCapturedAt: stamps)

        try Paths.ensureDirectory(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
