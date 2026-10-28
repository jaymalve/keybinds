/// Short labels for click mode. No label is the start of another, so a label fires the moment it's typed.
public enum HintLabels {
    /// Home row first, then the rows above and below.
    public static let alphabet = Array("fjdkslaghrueiwoqptyvbcnmxz")

    /// `count` labels: as many single letters as fit, the rest two (or more) letters. Earlier elements get the
    /// shorter labels.
    public static func make(_ count: Int, alphabet: [Character] = alphabet) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        // Breadth-first: expanding a label turns it into a prefix, which then can't be used itself.
        var labels = [""]
        var next = 0
        while labels.count - next < count {
            let prefix = labels[next]
            next += 1
            labels += alphabet.map { prefix + String($0) }
        }
        return Array(labels[next..<next + count])
    }
}
