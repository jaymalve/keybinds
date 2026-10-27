// Spike M0.2: what the Accessibility API returns for every app's windows (incl. other Spaces, fullscreen, minimized).
// Run once with windows spread across Spaces / a fullscreen app / a minimized window, and compare with what you see.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    print("No Accessibility permission. Grant it to the app running this (System Settings → Privacy & Security → Accessibility), then retry.")
    exit(1)
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value as? T : nil
}

// Windows the window server knows about (all Spaces), to compare against AX. Titles here would need Screen Recording; we only count.
let cgWindows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

let t0 = Date()
var total = 0
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.25)
    let windows: [AXUIElement] = attr(axApp, kAXWindowsAttribute) ?? []
    let cgCount = cgWindows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                                     && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 50 }.count
    print("\(app.localizedName ?? "?")  — AX windows: \(windows.count), window-server windows: \(cgCount)")
    for w in windows {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(w, &id)
        let title: String = attr(w, kAXTitleAttribute) ?? ""
        let minimized: Bool = attr(w, kAXMinimizedAttribute) ?? false
        let fullscreen: Bool = attr(w, "AXFullScreen") ?? false
        let subrole: String = attr(w, kAXSubroleAttribute) ?? ""
        print("    [\(id)] \(title.isEmpty ? "(untitled)" : title)\(minimized ? "  MINIMIZED" : "")\(fullscreen ? "  FULLSCREEN" : "")  \(subrole)")
        total += 1
    }
}
print(String(format: "\n%d AX windows in %.0f ms. If an app shows fewer AX windows than window-server windows, the missing ones are likely on another Space.", total, Date().timeIntervalSince(t0) * 1000))
