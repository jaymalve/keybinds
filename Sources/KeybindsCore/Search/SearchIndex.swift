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
    }

    /// Subtitle (app name, URL host…) matches count for less than title matches.
    static let subtitleWeight = 0.8

    private let entries: [Entry]

    /// `targets` must already be in recency order; ties keep that order.
    public init(_ targets: [Target]) {
        entries = targets.map { Entry(target: $0, title: PreparedText($0.title), subtitle: PreparedText($0.subtitle)) }
    }

    /// Space-separated words must each match the title or the subtitle, in any order ("chr gmail").
    public func search(_ query: String) -> [RankedTarget] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0) }
        guard !tokens.isEmpty else {
            return entries.map { RankedTarget(target: $0.target, score: 0, titleMatches: [], subtitleMatches: []) }
        }

        var results: [(RankedTarget, Int)] = []
        for (order, entry) in entries.enumerated() {
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
            results.append((RankedTarget(target: entry.target, score: total,
                                         titleMatches: titleHits, subtitleMatches: subtitleHits), order))
        }
        results.sort { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
        return results.map(\.0)
    }
}
