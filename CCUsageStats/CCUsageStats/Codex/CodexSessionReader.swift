import Foundation

/// Finds the newest Codex rate-limit reading in the CLI's session logs.
///
/// Read-only and local: no credentials, no network. The logs run to gigabytes
/// across hundreds of files, so it reads files newest-modified first, and only
/// their tails, widening a read only when a tail holds no reading.
nonisolated enum CodexSessionReader {
    static var defaultDirectory: URL {
Paths.liveCodexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    static let initialTailBytes = 256 * 1024
    /// The tail read never widens past this; a larger log is still read,
    /// just only its last `maxReadBytes`.
    static let maxReadBytes = 64 * 1024 * 1024
    /// Give up after this many files without a reading.
    static let maxFiles = 50

    /// With a `cache`, a file is only read when it changed since the last
    /// call, and a file that grew is read from where the last read stopped.
    /// Without one, a user whose logs hold no usable reading (API key, a
    /// foreign `limit_id`) had up to `maxFiles` × `maxReadBytes` re-read on
    /// every change under the sessions folder.
    static func latest(in directory: URL, cache: Cache? = nil) -> CodexSnapshot? {
        var best: CodexSnapshot?
        let files = rolloutFiles(in: directory)
        for (url, mtime) in files.prefix(maxFiles) {
            // A file can't hold an event newer than its last write, so once
            // the best reading beats a file's mtime, no older file can win.
            if let best, Double(best.observedAt) > mtime.timeIntervalSince1970 + 1 { break }
            let found = cache.map { $0.reading(for: url, mtime: mtime) } ?? latest(inFile: url)
            best = CodexSnapshot.newer(best, found)
        }
        cache?.forget(allBut: Set(files.map(\.0.path)))
        return best
    }

    /// What each rollout file held when last read. Safe to share between the
    /// scans of one monitor; they run one at a time.
    final class Cache: @unchecked Sendable {
        private struct Entry {
            let size: UInt64
            let mtime: Date
            let snapshot: CodexSnapshot?
        }
        /// A reading is one short line; this much overlap covers one that
        /// was still being written at the previous read.
        static let overlapBytes: UInt64 = 64 * 1024

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var read = 0
        /// Total bytes read through this cache.
        var bytesRead: Int { lock.lock(); defer { lock.unlock() }; return read }

        init() {}

        func reading(for url: URL, mtime: Date) -> CodexSnapshot? {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            lock.lock()
            let known = entries[url.path]
            lock.unlock()
            if let known, known.size == size, known.mtime == mtime { return known.snapshot }

            var count = 0
            let snapshot: CodexSnapshot?
            if let known, known.size > 0, size > known.size {
                // Appended to: only the new bytes can hold a newer reading.
                let from = known.size > Self.overlapBytes ? known.size - Self.overlapBytes : 0
                snapshot = CodexSnapshot.newer(known.snapshot, CodexSessionReader.latest(inFile: url, from: from, bytesRead: &count))
            } else {
                snapshot = CodexSessionReader.latest(inFile: url, bytesRead: &count)
            }
            lock.lock()
            entries[url.path] = Entry(size: size, mtime: mtime, snapshot: snapshot)
            read += count
            lock.unlock()
            return snapshot
        }

        func forget(allBut paths: Set<String>) {
            lock.lock()
            entries = entries.filter { paths.contains($0.key) }
            lock.unlock()
        }
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

    static func latest(inFile url: URL, maxRead: Int = maxReadBytes) -> CodexSnapshot? {
        var ignored = 0
        return latest(inFile: url, maxRead: maxRead, bytesRead: &ignored)
    }

    /// The newest reading in the bytes from `from` to the end (capped at the
    /// last `maxReadBytes`).
    static func latest(inFile url: URL, from: UInt64, bytesRead: inout Int) -> CodexSnapshot? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > from else { return nil }
        let start = max(from, size > UInt64(maxReadBytes) ? size - UInt64(maxReadBytes) : 0)
        guard (try? h.seek(toOffset: start)) != nil,
              let data = try? h.read(upToCount: Int(size - start)) else { return nil }
        bytesRead += data.count
        var text = Substring(String(decoding: data, as: UTF8.self))
        if start > 0, let nl = text.firstIndex(of: "\n") { text = text[text.index(after: nl)...] }
        return CodexRolloutParser.latest(inText: text)
    }

    static func latest(inFile url: URL, maxRead: Int = maxReadBytes, bytesRead: inout Int) -> CodexSnapshot? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return nil }

        var window = UInt64(min(initialTailBytes, maxRead))
        while true {
            let start = size > window ? size - window : 0
            guard (try? h.seek(toOffset: start)) != nil,
                  let data = try? h.read(upToCount: Int(size - start)) else { return nil }
            bytesRead += data.count
            var text = Substring(String(decoding: data, as: UTF8.self))
            // Mid-file, the first line is a fragment.
            if start > 0, let nl = text.firstIndex(of: "\n") { text = text[text.index(after: nl)...] }
            if let s = CodexRolloutParser.latest(inText: text) { return s }
            if start == 0 || window >= UInt64(maxRead) { return nil }
            window = min(window * 4, UInt64(maxRead))
        }
    }
}
