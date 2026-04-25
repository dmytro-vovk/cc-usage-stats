import Foundation

struct CachedState: Codable, Equatable {
    let capturedAt: Int64
    let snapshot: RateLimitsSnapshot

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    init(capturedAt: Int64, snapshot: RateLimitsSnapshot) {
        self.capturedAt = capturedAt
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        snapshot = RateLimitsSnapshot(
            fiveHour: try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour),
            sevenDay: try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encodeIfPresent(snapshot.fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(snapshot.sevenDay, forKey: .sevenDay)
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
    static func update(at url: URL, with incoming: RateLimitsSnapshot, now: Int64) throws {
        let existing = try read(at: url)?.snapshot
        let merged = RateLimitsSnapshot(
            fiveHour: incoming.fiveHour ?? existing?.fiveHour,
            sevenDay: incoming.sevenDay ?? existing?.sevenDay
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
