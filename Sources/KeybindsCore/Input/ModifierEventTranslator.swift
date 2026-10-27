import Foundation

/// Modifier state from a `flagsChanged` event, independent of AppKit.
public struct ModifierFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = ModifierFlags(rawValue: 1 << 0)
    public static let command = ModifierFlags(rawValue: 1 << 1)
    public static let option = ModifierFlags(rawValue: 1 << 2)
    public static let control = ModifierFlags(rawValue: 1 << 3)
    public static let function = ModifierFlags(rawValue: 1 << 4)
}

/// Turns full modifier-state snapshots into the edge events `DoubleTapDetector` consumes.
/// Caps Lock is deliberately not a modifier here, so double-Shift keeps working while it's on.
public struct ModifierEventTranslator: Sendable {
    private var shiftHeld = false

    public init() {}

    public mutating func flagsChanged(_ flags: ModifierFlags, at time: TimeInterval) -> [KeyEvent] {
        let shift = flags.contains(.shift)
        defer { shiftHeld = shift }

        // Any change while ⌘/⌥/⌃/fn is held means Shift is part of a shortcut, not a tap.
        if !flags.subtracting(.shift).isEmpty {
            return [.otherModifierDown(time)]
        }
        if shift && !shiftHeld { return [.shiftDown(time)] }
        if !shift && shiftHeld { return [.shiftUp(time)] }
        return []
    }
}
