import Foundation

public struct RankedTarget: Identifiable, Sendable {
    public let target: Target
    public let score: Int
    public let titleMatches: [Int]
    public let subtitleMatches: [Int]
    public var id: String { target.id }
}

/// Targets prepared for fast repeated searching. Rebuilt when the target list changes, queried per keystroke.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        let target: Target
        let title: PreparedText
        let subtitle: PreparedText
        let frecency: Double
    }

    /// Subtitle (app name, URL host…) matches count for less than title matches.
    static let subtitleWeight = 0.8
    /// Usage boost: ~12 points for something used once recently, capped so a strong text match still wins.
    static let maxBoost = 40.0

    /// Files rank a little below apps, windows and tabs with the same match.
    static let filePenalty = 12

    /// `t ` tabs only, `w ` windows only, `a ` apps only, `f ` files and folders only.
    static let scopes: [String: Set<TargetKind>] = [
        "t": [.browserTab, .terminalTab],
        "w": [.window],
        "a": [.app],
        "f": [.file, .folder],
    ]

    /// Splits off a scope prefix: the kinds it allows (nil = all) and the rest of the query.
    public static func parse(_ rawQuery: String) -> (kinds: Set<TargetKind>?, text: String) {
        let query = rawQuery.lowercased()
        if query.count >= 2, query.dropFirst().first == " ", let scope = scopes[String(query.prefix(1))] {
            return (scope, String(query.dropFirst(2)))
        }
        return (nil, query)
    }

    /// Merges two score-sorted result lists; on equal scores and duplicate ids, `a` wins.
    public static func merge(_ a: [RankedTarget], _ b: [RankedTarget]) -> [RankedTarget] {
        let ids = Set(a.map(\.id))
        let b = b.filter { !ids.contains($0.id) }
        var out: [RankedTarget] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j == b.count || (i < a.count && a[i].score >= b[j].score) { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        return out
    }

    private let entries: [Entry]

    /// `targets` must already be in recency order (previous target first); ties keep that order.
    public init(_ targets: [Target], frecency: (Target) -> Double = { _ in 0 }) {
        entries = targets.map {
            Entry(target: $0, title: PreparedText($0.title), subtitle: PreparedText($0.subtitle), frecency: frecency($0))
        }
    }

    /// True when the query has no search words, only an optional scope prefix: the palette is browsing.
    public static func isBrowsing(_ query: String) -> Bool {
        parse(query).text.allSatisfy(\.isWhitespace)
    }

    public func search(_ rawQuery: String) -> [RankedTarget] {
        let (kinds, query) = Self.parse(rawQuery)
        let pool = kinds.map { k in entries.filter { k.contains($0.target.kind) } } ?? entries
        let tokens = query.split(whereSeparator: \.isWhitespace).map { Array($0) }
        return tokens.isEmpty ? recents(pool, filesOnly: kinds == Self.scopes["f"]) : matches(tokens, in: pool)
    }

    /// Empty query: the previous target stays first (Enter = go back); then frequently used targets;
    /// then everything else in recency order. Files only show here once you've opened them from the palette,
    /// unless the `f ` scope asks for files.
    private func recents(_ pool: [Entry], filesOnly: Bool) -> [RankedTarget] {
        guard let first = pool.first else { return [] }
        let rest = pool.dropFirst()
        let used = rest.filter { $0.frecency >= 0.1 }.sorted { $0.frecency > $1.frecency }
        let unused = rest.filter { $0.frecency < 0.1 && (filesOnly || !$0.target.isFileSystem) }
        return ([first] + used + unused).map {
            RankedTarget(target: $0.target, score: 0, titleMatches: [], subtitleMatches: [])
        }
    }

    /// Space-separated words must each match the title or the subtitle, in any order ("chr gmail").
    private func matches(_ tokens: [[Character]], in pool: [Entry]) -> [RankedTarget] {
        var results: [(RankedTarget, Int)] = []
        for (order, entry) in pool.enumerated() {
            var total = 0
            var titleHits: [Int] = [], subtitleHits: [Int] = []
            var matchedAll = true
            for token in tokens {
                let t = FuzzyMatcher.match(token, in: entry.title)
                let s = FuzzyMatcher.match(token, in: entry.subtitle)
                let sScore = s.map { Int(Double($0.score) * Self.subtitleWeight) }
                switch (t, s) {
                case let (t?, _) where sScore == nil || t.score >= sScore!:
                    total += t.score
                    titleHits += t.positions
                case let (_, s?):
                    total += sScore!
                    subtitleHits += s.positions
                default:
                    matchedAll = false
                }
                if !matchedAll { break }
            }
            guard matchedAll else { continue }
            total += Int(min(Self.maxBoost, 12 * log2(1 + entry.frecency)))
            if entry.target.isFileSystem { total -= Self.filePenalty }
            results.append((RankedTarget(target: entry.target, score: total,
                                         titleMatches: titleHits, subtitleMatches: subtitleHits), order))
        }
        results.sort { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
        return results.map(\.0)
    }

    /// Files and folders go after everything else, most recently added first, whatever their match score.
    public static func filesByDateAdded(_ results: [RankedTarget]) -> [RankedTarget] {
        let files = results.filter(\.target.isFileSystem)
        guard !files.isEmpty else { return results }
        return results.filter { !$0.target.isFileSystem }
            + files.sorted { ($0.target.added ?? .distantPast) > ($1.target.added ?? .distantPast) }
    }
}
