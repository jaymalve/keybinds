import ApplicationServices

/// AXUIElement isn't Sendable; AX calls are safe from any thread, so wrap it to cross actors.
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
}

enum AX {
    /// Upper bound for any single AX call, so a hung app (e.g. Docker Desktop) can't stall a scan.
    /// Setting it on the system-wide element makes it the default for every element.
    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// For attributes whose value is another element (AXUIElement can't be cast with `as?`).
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    /// The app's menu item with this ⌘-only shortcut (e.g. "W"), found by shortcut so it works in any language.
    static func menuItem(pid: pid_t, commandKey: String) -> AXUIElement? {
        guard let bar = element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    let key: String? = attribute(item, kAXMenuItemCmdCharAttribute)
                    let mods: Int? = attribute(item, kAXMenuItemCmdModifiersAttribute)
                    if key == commandKey && mods == 0 { return item }
                }
            }
        }
        return nil
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
}
