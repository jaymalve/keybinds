// Spike M0.2b: find windows on *all* Spaces (incl. fullscreen) by brute-forcing AX remote tokens,
// the technique AltTab uses. Compares against plain kAXWindowsAttribute and times both per app.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

guard AXIsProcessTrusted() else { print("No Accessibility permission for this app."); exit(1) }

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v as? T : nil
}
func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }

/// Token layout: pid (Int32) | 0 (Int32) | 'coco' (Int32) | element id (UInt64).
func remoteWindows(pid: pid_t, budget: TimeInterval = 0.1, maxID: UInt64 = 1000) -> [AXUIElement] {
    var found: [AXUIElement] = []
    let start = Date()
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    for id in 0..<maxID {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
        if let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() {
            let sub: String? = attr(el, kAXSubroleAttribute)
            if sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole { found.append(el) }
        }
        if Date().timeIntervalSince(start) > budget { break }
    }
    return found
}

let t0 = Date()
var plainTotal = 0, remoteTotal = 0
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.25)

    let tp = Date()
    let plain: [AXUIElement] = attr(axApp, kAXWindowsAttribute) ?? []
    let plainMs = ms(tp)
    let plainIDs = Set(plain.map { el -> CGWindowID in var id: CGWindowID = 0; _ = _AXUIElementGetWindow(el, &id); return id })

    let tr = Date()
    let remote = remoteWindows(pid: pid)
    let remoteMs = ms(tr)

    // Union by window id.
    var byID: [CGWindowID: AXUIElement] = [:]
    for el in plain + remote { var id: CGWindowID = 0; _ = _AXUIElementGetWindow(el, &id); if id != 0 { byID[id] = el } }
    plainTotal += plainIDs.subtracting([0]).count; remoteTotal += byID.count

    print(String(format: "%@ — plain: %d (%.0f ms), all-spaces: %d (%.0f ms)",
                 app.localizedName ?? "?", plainIDs.subtracting([0]).count, plainMs, byID.count, remoteMs))
    for (id, el) in byID.sorted(by: { $0.key < $1.key }) {
        let title: String = attr(el, kAXTitleAttribute) ?? ""
        let min: Bool = attr(el, kAXMinimizedAttribute) ?? false
        let fs: Bool = attr(el, "AXFullScreen") ?? false
        let tag = plainIDs.contains(id) ? "" : "  ← other Space"
        print("    [\(id)] \(title.isEmpty ? "(untitled)" : String(title.prefix(70)))\(min ? "  MINIMIZED" : "")\(fs ? "  FULLSCREEN" : "")\(tag)")
    }
}
print(String(format: "\nplain AX: %d windows, all-spaces: %d windows, total %.0f ms", plainTotal, remoteTotal, ms(t0)))
