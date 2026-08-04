import Foundation

struct CachedState: Codable, Equatable {
    let capturedAt: Int64
    let snapshot: RateLimitsSnapshot

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
    }

    init(capturedAt: Int64, snapshot: RateLimitsSnapshot) {
        self.capturedAt = capturedAt
        self.snapshot = snapshot
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAt, forKey: .capturedAt)
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
    /// whatever is on disk for that field.
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
        let existing = try read(at: url)?.snapshot
        let merged = RateLimitsSnapshot(
            fiveHour: incoming.fiveHour ?? existing?.fiveHour,
            sevenDay: incoming.sevenDay ?? existing?.sevenDay,
            models: incoming.modelsAreAuthoritative ? incoming.models : [:]
        )
        let state = CachedState(capturedAt: now, snapshot: merged)

        try Paths.ensureDirectory(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
