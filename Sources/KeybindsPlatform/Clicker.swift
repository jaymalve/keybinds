import AppKit
import ApplicationServices

public enum ClickAction: Sendable {
    case click, commandClick, rightClick, hover
}

/// Acts on a labelled element. Buttons are pressed through Accessibility, which leaves the pointer alone; anything
/// else gets a real click at its center, and the pointer goes back where it was.
public enum Clicker {
    /// Roles whose AXPress does exactly what a click does. Text fields, rows and the rest need a real click
    /// (to place the caret, select the row…).
    static let pressRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXTab",
        "AXLink", "AXIncrementor", "AXColorWell", "AXMenuBarItem",
    ]

    public static func perform(_ action: ClickAction, on target: Clickable) {
        let element = target.ref.element
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        switch action {
        case .click:
            if pressRoles.contains(target.role),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
            click(at: center, button: .left, flags: [])
        case .commandClick:
            click(at: center, button: .left, flags: .maskCommand)
        case .rightClick:
            if AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success { return }
            click(at: center, button: .right, flags: [])
        case .hover:
            CGWarpMouseCursorPosition(center)
            post(.mouseMoved, at: center, button: .left, flags: [])
        }
    }

    private static func click(at point: CGPoint, button: CGMouseButton, flags: CGEventFlags) {
        let back = CGEvent(source: nil)?.location
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        post(.mouseMoved, at: point, button: button, flags: [])
        post(down, at: point, button: button, flags: flags)
        post(up, at: point, button: button, flags: flags)
        if let back {
            // Let the app take the click before the pointer moves away, or hover-driven UIs can miss it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CGWarpMouseCursorPosition(back)
                post(.mouseMoved, at: back, button: .left, flags: [])
            }
        }
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
