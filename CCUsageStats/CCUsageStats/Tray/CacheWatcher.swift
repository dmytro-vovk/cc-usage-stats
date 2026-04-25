import Foundation

/// Watches `state.json` for writes and re-attaches after atomic rename
/// (which unlinks the original inode). Fires `onChange` on the main queue.
/// The poller writes via atomic rename; this watcher also catches manual
/// edits made for testing/debugging.
final class CacheWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() { attach() }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func attach() {
        try? Paths.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
            let mask = src.data
            if mask.contains(.rename) || mask.contains(.delete) {
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.attach() }
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
    }
}
