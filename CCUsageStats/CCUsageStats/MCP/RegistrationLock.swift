import Foundation

/// An exclusive `flock` on a lock file: registration changes are multi-step
/// (CLI remove + add, read-modify-write of config.toml), and two of them —
/// a Settings toggle and the launch migration, possibly in two copies of
/// the app — must not interleave. Per open file, so it excludes other
/// threads of this process as well as other processes.
nonisolated enum RegistrationLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
