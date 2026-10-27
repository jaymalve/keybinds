// Spike M0.6: pure double-tap-Shift detector. No AppKit, so it can be replayed against recorded event streams.
import Foundation

enum KeyEvent {
    case shiftDown(TimeInterval)
    case shiftUp(TimeInterval)
    case otherModifierDown(TimeInterval)   // ⌘ ⌥ ⌃ fn, caps lock
    case keyDown(TimeInterval)             // any non-modifier key (no character recorded)
}

struct DoubleTapDetector {
    var maxHold: TimeInterval = 0.20
    var maxGap: TimeInterval = 0.30

    private enum State {
        case idle
        case firstDown(at: TimeInterval)
        case firstUp(at: TimeInterval)
        case secondDown(at: TimeInterval)
    }
    private var state: State = .idle

    /// Returns true exactly when a double tap completes (on the second Shift release).
    mutating func handle(_ e: KeyEvent) -> Bool {
        switch (state, e) {
        case (_, .keyDown), (_, .otherModifierDown):
            state = .idle
        case (.idle, .shiftDown(let t)):
            state = .firstDown(at: t)
        case (.firstDown(let d), .shiftUp(let t)):
            state = t - d <= maxHold ? .firstUp(at: t) : .idle
        case (.firstUp(let u), .shiftDown(let t)):
            state = t - u <= maxGap ? .secondDown(at: t) : .firstDown(at: t)
        case (.secondDown(let d), .shiftUp(let t)):
            state = .idle
            return t - d <= maxHold
        case (_, .shiftDown(let t)):
            state = .firstDown(at: t)
        case (_, .shiftUp):
            state = .idle
        }
        return false
    }
}
