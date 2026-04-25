import Foundation

enum Phase1Cleanup {
    private static let suffix = " statusline"

    static func run(settingsURL: URL, configURL: URL, sentinelURL: URL) throws {
        if FileManager.default.fileExists(atPath: sentinelURL.path) { return }
        defer { try? touchSentinel(sentinelURL) }

        guard var dict = try readDictionary(settingsURL) else { return }
        guard let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String,
              cmd.hasSuffix(suffix) else {
            return // not our integration; leave alone
        }

        // Determine restoration target from config.json (best effort).
        let wrappedCommand: String? = {
            guard let data = try? Data(contentsOf: configURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // wrappedCommand: explicit null -> nil; missing -> nil; string -> value
            if let v = obj["wrappedCommand"] as? String, !v.isEmpty { return v }
            return nil
        }()

        if let wrapped = wrappedCommand {
            dict["statusLine"] = ["type": "command", "command": wrapped]
        } else {
            dict.removeValue(forKey: "statusLine")
        }

        try writeDictionary(dict, to: settingsURL)
        try? FileManager.default.removeItem(at: configURL)
    }

    private static func readDictionary(_ url: URL) throws -> [String: Any]? {
        let resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        guard let data = try? Data(contentsOf: resolved), !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeDictionary(_ dict: [String: Any], to url: URL) throws {
        let resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmp = resolved.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(resolved, withItemAt: tmp)
    }

    private static func touchSentinel(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
