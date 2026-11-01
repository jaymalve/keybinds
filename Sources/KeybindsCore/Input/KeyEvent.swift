import Foundation

/// A keyboard event reduced to what the tap detector needs. Never carries characters or key codes.
public enum KeyEvent: Equatable, Sendable {
    case optionDown(TimeInterval)
    case optionUp(TimeInterval)
    /// ⌘ ⇧ ⌃ or fn changed while held. Invalidates any tap in progress.
    case otherModifierDown(TimeInterval)
    /// Any non-modifier key, or a mouse button.
    case keyDown(TimeInterval)
}
