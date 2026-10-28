import AppKit
import ApplicationServices

// SPIKE (M6): how fast can we find every clickable, visible element in the front window of real apps?
// Run with: open -n build/Keybinds.app --env KB_AX_SPIKE=1 ; results go to /tmp/axspike/results.txt

fileprivate struct Box: @unchecked Sendable { let el: AXUIElement }

fileprivate final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0, nodes = 0, hits = 0
    func add(calls c: Int = 0, nodes n: Int = 0, hits h: Int = 0) {
        lock.lock(); calls += c; nodes += n; hits += h; lock.unlock()
    }
}

fileprivate enum AXSpikeImpl {
    static let actionable: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXMenuBarItem",
        "AXRow", "AXCell", "AXTab", "AXSegmentedControl", "AXColorWell", "AXDockItem",
    ]
    static let maxNodes = 30_000

    static func run() {
        var out = "AX spike \(Date())\n"
        func say(_ s: String) { out += s + "\n"; print(s) }
        let wanted: [String: String] = [
            "com.google.Chrome": "chrome", "com.apple.Safari": "native", "com.apple.finder": "native",
            "com.apple.systempreferences": "native", "com.todesktop.230313mzl4w4u92": "electron",
            "com.anthropic.claudefordesktop": "electron", "com.t3tools.t3code": "electron",
            "com.spotify.client": "cef", "net.whatsapp.WhatsApp": "native", "com.apple.Notes": "native",
            "com.apple.MobileSMS": "native", "com.openai.codex": "native", "com.apple.Music": "native",
            "com.electron.dockerdesktop": "electron",
        ]
        let apps = NSWorkspace.shared.runningApplications.filter { wanted[$0.bundleIdentifier ?? ""] != nil }
        say(String(format: "%-16@ %-9@ %6@ %6@ %8@ | %9@ %9@ %9@ %9@ | %@", "app" as NSString, "kind" as NSString,
                   "nodes" as NSString, "hits" as NSString, "calls" as NSString, "cold" as NSString,
                   "naive" as NSString, "batched" as NSString, "parallel" as NSString, "notes" as NSString))
        for app in apps {
            let kind = wanted[app.bundleIdentifier!]!
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 1.0)
            var notes: [String] = []
            var setEnhanced = false
            if kind == "electron" || kind == "cef" {
                let r = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                notes.append("manualAX=\(r.rawValue)")
            } else if kind == "chrome" {
                let r = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                notes.append("enhancedUI=\(r.rawValue)")
                setEnhanced = r == .success
            }
            guard let window = window(of: appEl) else {
                say(String(format: "%-16@ %-9@ no window on this Space", (app.localizedName ?? "?") as NSString, kind as NSString))
                continue
            }
            let bounds = frame(window) ?? .zero
            if let t: String = attr(window, kAXTitleAttribute) { notes.append("“\(t.prefix(28))”") }

            // Cold: first batched walk right after enabling accessibility (Chrome/Electron build the tree lazily).
            let cold = time { _ = batched(Box(el: window), bounds) }
            var naiveT: [Double] = [], batchT: [Double] = [], parT: [Double] = []
            var last = Counter()
            for _ in 0..<3 {
                naiveT.append(time { _ = naive(Box(el: window), bounds) })
                batchT.append(time { last = batched(Box(el: window), bounds) })
                parT.append(time { _ = parallel(Box(el: window), bounds) })
            }
            say(String(format: "%-16@ %-9@ %6d %6d %8d | %7.0fms %7.0fms %7.0fms %7.0fms | %@",
                       String((app.localizedName ?? "?").prefix(16)) as NSString, kind as NSString,
                       last.nodes, last.hits, last.calls, cold, median(naiveT), median(batchT), median(parT),
                       notes.joined(separator: " ") as NSString))
            if setEnhanced {
                AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
        }
        try? FileManager.default.createDirectory(atPath: "/tmp/axspike", withIntermediateDirectories: true)
        try? out.write(toFile: "/tmp/axspike/results.txt", atomically: true, encoding: .utf8)
    }

    // MARK: walkers

    /// One AX call per attribute; no pruning.
    static func naive(_ root: Box, _ bounds: CGRect) -> Counter {
        let c = Counter()
        func walk(_ el: AXUIElement, depth: Int) {
            guard c.nodes < maxNodes, depth < 80 else { return }
            c.add(calls: 4, nodes: 1)
            let role: String? = attr(el, kAXRoleAttribute)
            if let role, actionable.contains(role), let f = frame(el), f.intersects(bounds), f.width > 1 { c.add(hits: 1) }
            let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
            c.add(calls: 1)
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(root.el, depth: 0)
        return c
    }

    /// One batched call per element (role, children, position, size); prunes subtrees outside the window,
    /// and uses visible children/rows for lists and tables.
    static func batched(_ root: Box, _ bounds: CGRect) -> Counter {
        let c = Counter()
        func walk(_ el: AXUIElement, depth: Int) {
            guard c.nodes < maxNodes, depth < 80 else { return }
            let (role, kids, f) = fetch(el, c)
            c.add(nodes: 1)
            if let f, f.width > 0, f.height > 0, !f.intersects(bounds) { return }
            if let role, actionable.contains(role), let f, f.width > 1 { c.add(hits: 1) }
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(root.el, depth: 0)
        return c
    }

    /// Batched, with the window's top-level subtrees walked concurrently.
    static func parallel(_ root: Box, _ bounds: CGRect) -> Counter {
        let c = Counter()
        func walk(_ el: AXUIElement, depth: Int) {
            guard c.nodes < maxNodes, depth < 80 else { return }
            let (role, kids, f) = fetch(el, c)
            c.add(nodes: 1)
            if let f, f.width > 0, f.height > 0, !f.intersects(bounds) { return }
            if let role, actionable.contains(role), let f, f.width > 1 { c.add(hits: 1) }
            for k in kids { walk(k, depth: depth + 1) }
        }
        // Fan out two levels down so there's enough independent work.
        var frontier = [root.el]
        for _ in 0..<2 {
            var next: [AXUIElement] = []
            for el in frontier {
                let (role, kids, f) = fetch(el, c)
                c.add(nodes: 1)
                if let role, actionable.contains(role), let f, f.width > 1 { c.add(hits: 1) }
                next += kids
            }
            frontier = next
        }
        let boxes = frontier.map(Box.init)
        DispatchQueue.concurrentPerform(iterations: boxes.count) { i in walk(boxes[i].el, depth: 2) }
        return c
    }

    nonisolated(unsafe) private static let batchAttrs = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                     "AXVisibleChildren", "AXVisibleRows"] as CFArray

    private static func fetch(_ el: AXUIElement, _ c: Counter) -> (String?, [AXUIElement], CGRect?) {
        var values: CFArray?
        c.add(calls: 1)
        guard AXUIElementCopyMultipleAttributeValues(el, batchAttrs, [], &values) == .success,
              let v = values as? [AnyObject], v.count == 6 else { return (nil, [], nil) }
        let role = v[0] as? String
        var kids = (v[1] as? [AXUIElement]) ?? []
        if let rows = v[5] as? [AXUIElement], !rows.isEmpty { kids = rows }
        else if let vis = v[4] as? [AXUIElement], !vis.isEmpty, vis.count < kids.count { kids = vis }
        var f: CGRect?
        if CFGetTypeID(v[2]) == AXValueGetTypeID(), CFGetTypeID(v[3]) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(v[2] as! AXValue, .cgPoint, &p)
            AXValueGetValue(v[3] as! AXValue, .cgSize, &s)
            f = CGRect(origin: p, size: s)
        }
        return (role, kids, f)
    }

    // MARK: helpers

    static func window(of app: AXUIElement) -> AXUIElement? {
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) { return w }
        if let w: AXUIElement = attr(app, kAXMainWindowAttribute) { return w }
        let ws: [AXUIElement]? = attr(app, kAXWindowsAttribute)
        return ws?.first
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func time(_ f: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        f()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
}

enum AXSpike {
    static func run() { AXSpikeImpl.run() }
}
