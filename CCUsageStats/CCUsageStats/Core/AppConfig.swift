import Foundation

struct AppConfig: Codable, Equatable {
    var wrappedCommand: String?

    static let empty = AppConfig(wrappedCommand: nil)

    static func read(at url: URL) throws -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .empty
        }
        return config
    }

    static func write(_ config: AppConfig, to url: URL) throws {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
