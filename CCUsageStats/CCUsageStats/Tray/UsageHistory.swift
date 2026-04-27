import Foundation

/// One observed sample: epoch seconds + 5-hour utilization percentage.
struct UsageSample: Codable, Equatable {
    let t: Int64
    let p: Double
}

/// Append-only JSONL log of 5-hour utilization samples, kept trimmed to the
/// current rolling window. In-memory copy mirrors the file for fast reads.
@MainActor
final class UsageHistory {
    private let url: URL
    private(set) var samples: [UsageSample]

    init(url: URL) {
        self.url = url
        self.samples = (try? Self.load(from: url)) ?? []
    }

    /// Append `sample`. Drop existing entries with `t < keepFromEpoch`.
    /// Best-effort persistence — IO errors are swallowed (the chart is
    /// non-critical UI).
    func append(_ sample: UsageSample, keepFromEpoch: Int64) {
        let trimmed = samples.filter { $0.t >= keepFromEpoch }
        let didTrim = trimmed.count != samples.count
        // Avoid duplicate timestamps (same captured_at as last sample).
        if let last = trimmed.last, last.t == sample.t {
            samples = trimmed
            samples[samples.count - 1] = sample
            try? Self.rewrite(samples, to: url)
            return
        }
        samples = trimmed + [sample]
        do {
            if didTrim {
                try Self.rewrite(samples, to: url)
            } else {
                try Self.appendOne(sample, to: url)
            }
        } catch {
            // ignore
        }
    }

    // MARK: - File I/O

    private static func load(from url: URL) throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var out: [UsageSample] = []
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            if let s = try? decoder.decode(UsageSample.self, from: Data(line)) {
                out.append(s)
            }
        }
        return out
    }

    private static func rewrite(_ samples: [UsageSample], to url: URL) throws {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        var data = Data()
        for s in samples {
            data.append(try encoder.encode(s))
            data.append(0x0a)
        }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func appendOne(_ sample: UsageSample, to url: URL) throws {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        var data = try encoder.encode(sample)
        data.append(0x0a)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
