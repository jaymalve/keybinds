import Foundation

/// A keyboard event reduced to what the double-tap detector needs. Never carries characters or key codes.
public enum KeyEvent: Equatable, Sendable {
    case shiftDown(TimeInterval)
    case shiftUp(TimeInterval)
    /// ⌘ ⌥ ⌃ or fn changed while held. Invalidates any tap in progress.
    case otherModifierDown(TimeInterval)
    /// Any non-modifier key.
    case keyDown(TimeInterval)
}
