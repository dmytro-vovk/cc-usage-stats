import Foundation

enum Installer {
    enum State: Equatable { case installed, notInstalled }
    enum InstallError: Error { case malformedSettings, ioError(Error) }

    private static func ourCommand(for binaryPath: String) -> String {
        "\(binaryPath) statusline"
    }

    static func currentState(settingsURL: URL, binaryPath: String) throws -> State {
        let dict = try readDictionary(settingsURL)
        guard let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return .notInstalled }
        return cmd == ourCommand(for: binaryPath) ? .installed : .notInstalled
    }

    /// Returns the binary path currently configured in settings.json's statusLine.command,
    /// stripped of trailing " statusline". Nil if no statusLine.
    static func installedBinaryPath(settingsURL: URL) throws -> String? {
        let dict = try readDictionary(settingsURL)
        guard let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return nil }
        let suffix = " statusline"
        guard cmd.hasSuffix(suffix) else { return nil }
        return String(cmd.dropLast(suffix.count))
    }

    /// Wrap the existing statusLine.command (if any) and replace with ours.
    /// Idempotent: if already installed, does NOT overwrite wrappedCommand.
    static func install(settingsURL: URL, configURL: URL, binaryPath: String) throws {
        var dict = try readDictionary(settingsURL)
        let target = ourCommand(for: binaryPath)

        let alreadyInstalled: Bool = {
            guard let sl = dict["statusLine"] as? [String: Any],
                  let cmd = sl["command"] as? String else { return false }
            return cmd == target
        }()

        if !alreadyInstalled {
            // Capture previous command.
            let previous = (dict["statusLine"] as? [String: Any])?["command"] as? String
            try AppConfig.write(.init(wrappedCommand: previous), to: configURL)
        }
        // else: leave config.json untouched.

        try createBackup(settingsURL)

        dict["statusLine"] = [
            "type": "command",
            "command": target
        ]
        try writeDictionary(dict, to: settingsURL)
    }

    /// Restore previously-wrapped command (if any) from config.json.
    static func uninstall(settingsURL: URL, configURL: URL, binaryPath: String) throws {
        var dict = try readDictionary(settingsURL)
        let conf = try AppConfig.read(at: configURL)

        try createBackup(settingsURL)

        if let wrapped = conf.wrappedCommand, !wrapped.isEmpty {
            dict["statusLine"] = ["type": "command", "command": wrapped]
        } else {
            dict.removeValue(forKey: "statusLine")
        }
        try writeDictionary(dict, to: settingsURL)
    }

    // MARK: - helpers

    /// Resolve POSIX symlinks (NOT Finder aliases) so we edit the actual target file.
    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
    }

    private static func readDictionary(_ url: URL) throws -> [String: Any] {
        let r = resolved(url)
        guard let data = try? Data(contentsOf: r) else { return [:] }
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw InstallError.malformedSettings
        }
        return dict
    }

    private static func writeDictionary(_ dict: [String: Any], to url: URL) throws {
        let r = resolved(url)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmp = r.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(r, withItemAt: tmp)
    }

    private static func createBackup(_ url: URL) throws {
        let r = resolved(url)
        guard FileManager.default.fileExists(atPath: r.path) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let ts = fmt.string(from: Date())
        let unique = UUID().uuidString.prefix(8)
        let backup = r.appendingPathExtension("bak.\(ts)-\(unique)")
        try FileManager.default.copyItem(at: r, to: backup)
    }
}
