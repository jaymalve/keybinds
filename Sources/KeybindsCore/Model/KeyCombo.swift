import Foundation

/// A key combination such as ⌘K. `keyCode` is the macOS virtual key code (kVK_ANSI_K = 40).
public struct KeyCombo: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case command, option, control, shift
    }

    public var keyCode: UInt32
    public var modifiers: Set<Modifier>
    /// The key as typed when recorded ("K"), for display only.
    public var keyLabel: String?

    public init(keyCode: UInt32, modifiers: Set<Modifier>, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// "⌃⌥⇧⌘K" in the standard macOS modifier order.
    public var displayString: String {
        let order: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + (keyLabel ?? "key \(keyCode)")
    }
}
