import Foundation

public struct DoubleTapTiming: Codable, Equatable, Sendable {
    /// Longest a single Shift tap may be held.
    public var maxHold: TimeInterval
    /// Longest pause between releasing the first tap and pressing the second.
    public var maxGap: TimeInterval

    /// Tuned in spike M0.6: deliberate taps measured ~88 ms hold and ~67 ms gap.
    public static let `default` = DoubleTapTiming(maxHold: 0.20, maxGap: 0.30)

    public init(maxHold: TimeInterval, maxGap: TimeInterval) {
        self.maxHold = maxHold
        self.maxGap = maxGap
    }
}

/// Recognizes two quick, "pure" Shift taps: no other key or modifier pressed in between.
public struct DoubleTapDetector: Sendable {
    public var timing: DoubleTapTiming

    private enum State: Sendable {
        case idle
        case firstDown(at: TimeInterval)
        case firstUp(at: TimeInterval)
        case secondDown(at: TimeInterval)
    }
    private var state: State = .idle

    public init(timing: DoubleTapTiming = .default) {
        self.timing = timing
    }

    /// Returns true exactly when a double tap completes, on the second Shift release.
    public mutating func handle(_ event: KeyEvent) -> Bool {
        switch (state, event) {
        case (_, .keyDown), (_, .otherModifierDown):
            state = .idle
        case (.idle, .shiftDown(let t)):
            state = .firstDown(at: t)
        case (.firstDown(let down), .shiftUp(let t)):
            state = t - down <= timing.maxHold ? .firstUp(at: t) : .idle
        case (.firstUp(let up), .shiftDown(let t)):
            state = t - up <= timing.maxGap ? .secondDown(at: t) : .firstDown(at: t)
        case (.secondDown(let down), .shiftUp(let t)):
            state = .idle
            return t - down <= timing.maxHold
        case (_, .shiftDown(let t)):
            state = .firstDown(at: t)
        case (_, .shiftUp):
            state = .idle
        }
        return false
    }
}
