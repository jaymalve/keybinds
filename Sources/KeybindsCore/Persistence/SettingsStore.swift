import Foundation

/// Reads and writes `settings.json` in Application Support.
public struct SettingsStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybinds", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    /// Missing file → defaults. Unreadable file → throws, so a typo doesn't silently reset settings.
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
