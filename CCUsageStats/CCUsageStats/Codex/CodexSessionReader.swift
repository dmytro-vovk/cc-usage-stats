import Foundation

/// Finds the newest Codex rate-limit reading in the CLI's session logs.
///
/// Read-only and local: no credentials, no network. The logs run to gigabytes
/// across hundreds of files, so it reads files newest-modified first, and only
/// their tails, widening a read only when a tail holds no reading.
nonisolated enum CodexSessionReader {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static let initialTailBytes = 256 * 1024
    /// A larger log than this is skipped rather than read whole.
    static let maxReadBytes = 64 * 1024 * 1024
    /// Give up after this many files without a reading.
    static let maxFiles = 50

    static func latest(in directory: URL) -> CodexSnapshot? {
        var best: CodexSnapshot?
        for (url, mtime) in rolloutFiles(in: directory).prefix(maxFiles) {
            // A file can't hold an event newer than its last write, so once
            // the best reading beats a file's mtime, no older file can win.
            if let best, Double(best.observedAt) > mtime.timeIntervalSince1970 + 1 { break }
            best = CodexSnapshot.newer(best, latest(inFile: url))
        }
        return best
    }

    /// Rollout files under `directory`, most recently modified first.
    static func rolloutFiles(in directory: URL) -> [(URL, Date)] {
        guard let e = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true
            else { continue }
            files.append((url, v.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }
    }

    static func latest(inFile url: URL) -> CodexSnapshot? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0, size <= UInt64(maxReadBytes) else { return nil }

        var window = UInt64(initialTailBytes)
        while true {
            let start = size > window ? size - window : 0
            guard (try? h.seek(toOffset: start)) != nil,
                  let data = try? h.read(upToCount: Int(size - start)) else { return nil }
            var text = Substring(String(decoding: data, as: UTF8.self))
            // Mid-file, the first line is a fragment.
            if start > 0, let nl = text.firstIndex(of: "\n") { text = text[text.index(after: nl)...] }
            if let s = CodexRolloutParser.latest(inText: text) { return s }
            if start == 0 { return nil }
            window *= 4
        }
    }
}
