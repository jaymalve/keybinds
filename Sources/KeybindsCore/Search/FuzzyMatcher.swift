import Foundation

/// fzf-style subsequence matcher. Query characters must appear in order; the score rewards
/// matches at word starts, camelCase humps and consecutive runs, and penalizes gaps.
public enum FuzzyMatcher {
    public struct Match: Sendable {
        public let score: Int
        /// Character offsets in the candidate that matched, for highlighting.
        public let positions: [Int]
    }

    static let matchScore = 16
    static let firstCharBonus = 10
    static let wordStartBonus = 9
    static let camelBonus = 7
    static let consecutiveBonus = 6
    static let gapPenalty = 1

    /// `candidate` must be prepared with `PreparedText` so lowercasing happens once per target, not per keystroke.
    public static func match(_ query: [Character], in candidate: PreparedText) -> Match? {
        let text = candidate.lowered
        let n = query.count, m = text.count
        guard n > 0 else { return Match(score: 0, positions: []) }
        guard n <= m else { return nil }

        // Quick reject: is the query a subsequence at all?
        var qi = 0
        for c in text where c == query[qi] {
            qi += 1
            if qi == n { break }
        }
        guard qi == n else { return nil }

        // dp[i][j]: best score with query[i] matched at text[j]. back[i][j]: where query[i-1] matched.
        let minus = Int.min / 4
        var dp = [[Int]](repeating: [Int](repeating: minus, count: m), count: n)
        var back = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)

        for j in 0..<m where text[j] == query[0] {
            // Leading gap costs a little, so earlier matches win ties.
            dp[0][j] = matchScore + candidate.bonus[j] + (j == 0 ? firstCharBonus : 0) - min(j, 10) * gapPenalty
        }
        for i in 1..<n {
            // Running best of dp[i-1][k] + k*gapPenalty for k < j-1 (linear gap penalty).
            var bestGap = minus, bestGapK = -1
            for j in i..<m {
                if j >= 2, dp[i - 1][j - 2] > minus {
                    let v = dp[i - 1][j - 2] + (j - 2) * gapPenalty
                    if v > bestGap { bestGap = v; bestGapK = j - 2 }
                }
                guard text[j] == query[i] else { continue }
                var best = minus, from = -1
                if dp[i - 1][j - 1] > minus {
                    best = dp[i - 1][j - 1] + consecutiveBonus
                    from = j - 1
                }
                if bestGap > minus {
                    let v = bestGap - (j - 1) * gapPenalty
                    if v > best { best = v; from = bestGapK }
                }
                guard from >= 0 else { continue }
                dp[i][j] = best + matchScore + candidate.bonus[j]
                back[i][j] = from
            }
        }

        var end = -1, score = minus
        for j in 0..<m where dp[n - 1][j] > score {
            score = dp[n - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: n)
        var j = end
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            j = back[i][j]
        }
        // Slight preference for shorter candidates.
        return Match(score: score - m / 8, positions: positions)
    }
}

/// A candidate string lowercased and annotated with per-character bonuses, computed once.
public struct PreparedText: Sendable {
    public let original: String
    let lowered: [Character]
    let bonus: [Int]

    public init(_ string: String) {
        original = string
        let chars = Array(string)
        lowered = chars.map { c in
            let l = c.lowercased()
            return l.count == 1 ? Character(l) : c
        }
        var bonus = [Int](repeating: 0, count: chars.count)
        for (j, c) in chars.enumerated() where j > 0 {
            let prev = chars[j - 1]
            if !prev.isLetter && !prev.isNumber && (c.isLetter || c.isNumber) {
                bonus[j] = FuzzyMatcher.wordStartBonus
            } else if prev.isLowercase && c.isUppercase {
                bonus[j] = FuzzyMatcher.camelBonus
            }
        }
        if !chars.isEmpty { bonus[0] = FuzzyMatcher.wordStartBonus }
        self.bonus = bonus
    }
}
