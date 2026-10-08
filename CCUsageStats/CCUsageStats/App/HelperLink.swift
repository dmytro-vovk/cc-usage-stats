import Foundation

/// A stable path to this app's executable for agents to launch:
/// `~/Library/Application Support/cc-usage-stats/bin/ccusagestats`, a
/// symlink every launch repoints at the running copy. MCP registrations name
/// the link rather than the bundle, so moving or reinstalling the app
/// doesn't break them.
nonisolated enum HelperLink {
    static func link(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent("bin/ccusagestats")
    }

    /// Gatekeeper runs a quarantined app that hasn't been moved from its
    /// download folder from a randomised read-only mount; that path is gone
    /// after quit, so it must never become the link's target.
    static func isTranslocated(_ executable: String) -> Bool {
        executable.contains("/AppTranslocation/")
    }

    /// A copy's own executable (`…/X.app/Contents/MacOS/CCUsageStats`) — what
    /// registrations named before the link existed.
    static func isBundleExecutable(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/MacOS/CCUsageStats")
    }

    /// Points the link at `executable`, unless it is translocated. Returns the
    /// link's path, or nil when skipped.
    @discardableResult
    static func install(appSupport: URL, executable: String) throws -> String? {
        guard !isTranslocated(executable) else { return nil }
        return try update(link: link(in: appSupport), target: executable)
    }

    /// Atomically (re)points `link` at `target`: a fresh symlink renamed over
    /// the old one, so an agent starting at that moment never sees it missing.
    /// Only ever replaces a symlink, and only inside a real `bin` directory —
    /// never a file or directory someone else put there.
    @discardableResult
    static func update(link: URL, target: String) throws -> String {
        let fm = FileManager.default
        let dir = link.deletingLastPathComponent()
        if let type = fileType(dir.path), type != S_IFDIR { throw POSIXError(.ENOTDIR) }
        if let type = fileType(link.path), type != S_IFLNK { throw POSIXError(.EEXIST) }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target { return link.path }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(".\(link.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? fm.removeItem(at: staged)
        try fm.createSymbolicLink(atPath: staged.path, withDestinationPath: target)
        guard rename(staged.path, link.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staged)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return link.path
    }

    /// `lstat` file type (`S_IFLNK`, `S_IFDIR`, …), nil when absent.
    private static func fileType(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// The command to register: the link while it leads to this executable,
    /// otherwise (translocated, link failed, another copy launched since) the
    /// executable itself.
    static func registrationCommand(link: URL, executable: String) -> String {
        let resolved = link.resolvingSymlinksInPath().path
        let here = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        return resolved == here && resolved != link.path ? link.path : executable
    }

    // MARK: - Live

    static var liveLink: URL { link(in: Paths.appSupportDir) }

    static var liveExecutable: String { Bundle.main.executablePath ?? "" }

    static var liveRegistrationCommand: String {
        registrationCommand(link: liveLink, executable: liveExecutable)
    }
}
