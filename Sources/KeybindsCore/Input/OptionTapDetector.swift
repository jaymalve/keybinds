import Foundation

/// Recognizes one quick, "pure" ⌥ tap: no other key, modifier or click before it's released.
public struct OptionTapDetector: Sendable {
    /// Shorter than `HotkeyManager.holdDelay`, so one press can't be both a tap and a hold.
    public static let maxHold: TimeInterval = 0.20

    private var downAt: TimeInterval?

    public init() {}

    /// Returns true exactly when a tap completes, on the ⌥ release.
    public mutating func handle(_ event: KeyEvent) -> Bool {
        switch event {
        case .optionDown(let t):
            downAt = t
        case .optionUp(let t):
            defer { downAt = nil }
            return downAt.map { t - $0 <= Self.maxHold } ?? false
        case .otherModifierDown, .keyDown:
            downAt = nil
        }
        return false
    }
}
