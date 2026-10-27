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

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
}
