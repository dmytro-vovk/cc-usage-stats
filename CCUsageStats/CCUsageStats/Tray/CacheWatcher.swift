import Foundation

/// Watches `state.json` for writes and re-attaches after atomic rename
/// (which unlinks the original inode). Fires `onChange` on the main queue.
/// The poller writes via atomic rename; this watcher also catches manual
/// edits made for testing/debugging.
///
/// Everything — events, re-attach, `start`/`stop` — runs on the main queue,
/// so there is one owner of `source`, and each source closes the descriptor
/// it was created with, exactly once, in its cancel handler.
final class CacheWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = true

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stopped = false
        attach()
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    private func attach() {
        guard !stopped, source == nil else { return }
        try? Paths.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // An event queued before `stop()` (or before a re-attach
                // replaced this source) is no longer wanted.
                guard let self, self.source === src else { return }
                self.onChange()
                let mask = src.data
                guard mask.contains(.rename) || mask.contains(.delete) else { return }
                src.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.stopped, self.source == nil else { return }
                        self.attach()
                        // A write that landed while nothing was watching.
                        self.onChange()
                    }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
