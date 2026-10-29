import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "click")

/// Something in a window you can click.
public struct Clickable: Sendable {
    let ref: AXRef
    /// Screen coordinates with the origin at the top left of the main screen (AX's convention).
    public let frame: CGRect
    public let role: String
    public let title: String
}

/// Finds every visible clickable element in an app's focused window.
///
/// One batched AX call per element, and subtrees outside the visible area are skipped: the M6 spike measured
/// 11–50 ms for native apps and 50–130 ms for Chrome and Electron this way (one call per attribute took 2.8 s in Notes).
public enum ElementScanner {
    /// Roles worth a label. Table cells are left out: their row gets one.
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXRow", "AXTab",
        "AXColorWell", "AXSearchField", "AXMenuBarItem",
    ]
    /// Containers that cut off what's scrolled out of view.
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline", "AXBrowser"]

    static let maxNodes = 20_000
    static let maxResults = 600
    static let timeLimit: TimeInterval = 1.5

    nonisolated(unsafe) private static let attributes = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                     "AXVisibleChildren", "AXVisibleRows", kAXTitleAttribute, kAXDescriptionAttribute,
                                     "AXPlaceholderValue"] as CFArray

    /// Blocking; call off the main thread.
    /// The focused window's frame (AX coordinates) and what's clickable in it.
    public static func scan(pid: pid_t) -> (window: CGRect, items: [Clickable]) {
        let start = Date()
        let app = AXUIElementCreateApplication(pid)
        enableAccessibility(app, pid: pid)
        guard let window = AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute),
              let windowFrame = frame(window) else {
            log.notice("no focused window for pid \(pid)")
            return (.zero, [])
        }
        var found: [Clickable] = []
        var seen = Set<String>()
        var nodes = 0
        let deadline = start.addingTimeInterval(timeLimit)

        func walk(_ element: AXUIElement, clip: CGRect, depth: Int) {
            guard nodes < maxNodes, found.count < maxResults, depth < 80 else { return }
            if nodes % 200 == 0, Date() > deadline { return }
            nodes += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
                  let v = values as? [AnyObject], v.count == 9 else { return }
            let role = v[0] as? String ?? ""
            let f = rect(v[2], v[3])
            var clip = clip
            if let f, f.width > 0, f.height > 0 {
                guard f.intersects(clip) else { return }
                if clippingRoles.contains(role) { clip = clip.intersection(f) }
            }
            if clickableRoles.contains(role), let f, f.width > 2, f.height > 2, clip.contains(CGPoint(x: f.midX, y: f.midY)) {
                // Nested clickables often share a frame (a link wrapping a button); keep the outer one.
                let key = "\(Int(f.minX / 4)),\(Int(f.minY / 4)),\(Int(f.width / 4)),\(Int(f.height / 4))"
                if seen.insert(key).inserted {
                    let title = [v[6], v[7], v[8]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
                    found.append(Clickable(ref: AXRef(element: element), frame: f, role: role, title: title))
                }
            }
            var children = v[1] as? [AXUIElement] ?? []
            if let rows = v[5] as? [AXUIElement], !rows.isEmpty {
                children = rows
            } else if let visible = v[4] as? [AXUIElement], !visible.isEmpty, visible.count < children.count {
                children = visible
            }
            for child in children { walk(child, clip: clip, depth: depth + 1) }
        }
        walk(window, clip: windowFrame, depth: 0)
        found.sort { abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        log.notice("scan pid \(pid): \(nodes) nodes, \(found.count) clickable in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return (windowFrame, found)
    }

    nonisolated(unsafe) private static var enabled = Set<pid_t>()
    private static let enabledLock = NSLock()

    /// Electron and Chromium apps only build their accessibility tree once an assistive app asks for it.
    private static func enableAccessibility(_ app: AXUIElement, pid: pid_t) {
        enabledLock.lock()
        let first = enabled.insert(pid).inserted
        enabledLock.unlock()
        guard first else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
        return rect(p, s)
    }

    private static func rect(_ p: CFTypeRef?, _ s: CFTypeRef?) -> CGRect? {
        guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
