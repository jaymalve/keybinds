import Foundation

/// How often and how recently each target was opened ("frecency"), keyed by `Target.historyKey`.
/// Each use adds 1 to a score that halves every `halfLife`, so recent habits outweigh old ones.
public struct UsageHistory: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        var score: Double
        var lastUsed: Date
    }

    public static let halfLife: TimeInterval = 3 * 24 * 3600
    static let maxEntries = 2000

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func record(_ key: String, at now: Date = Date()) {
        entries[key] = Entry(score: frecency(key, at: now) + 1, lastUsed: now)
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { frecency($0.key, at: now) > frecency($1.key, at: now) }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    public func frecency(_ key: String, at now: Date = Date()) -> Double {
        guard let e = entries[key] else { return 0 }
        return e.score * pow(0.5, now.timeIntervalSince(e.lastUsed) / Self.halfLife)
    }
}

/// `history.json` in Application Support. History isn't precious: unreadable files start over.
public struct HistoryStore: Sendable {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL.deletingLastPathComponent().appendingPathComponent("history.json")) {
        self.url = url
    }

    public func load() -> UsageHistory {
        (try? JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: url))) ?? UsageHistory()
    }

    public func save(_ history: UsageHistory) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
    }
}
