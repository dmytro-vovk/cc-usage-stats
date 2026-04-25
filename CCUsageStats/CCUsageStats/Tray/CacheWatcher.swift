import Foundation

final class CacheWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        attach()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func attach() {
        // Ensure file exists so we can open it. If absent, create empty marker;
        // the cache writer will replace it atomically.
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
            // On rename/delete, atomic rename replaced the inode. Re-attach.
            let mask = src.data
            if mask.contains(.rename) || mask.contains(.delete) {
                self.stop()
                // Small retry — the new file may not exist yet for a microsecond.
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
