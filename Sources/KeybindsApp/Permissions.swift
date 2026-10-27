import AppKit
import ApplicationServices

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and adds Keybinds to the Accessibility list.
    static func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" == kAXTrustedCheckOptionPrompt (a C global Swift 6 won't let us touch).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
