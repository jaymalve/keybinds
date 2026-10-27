import AppKit
import ApplicationServices
import KeybindsCore
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "activate")

/// Brings a target to the front: unminimizes, switches Space, focuses the exact window.
@MainActor
public struct Activator {
    let index: TargetIndex

    public init(index: TargetIndex) {
        self.index = index
    }

    public func activate(_ target: Target) {
        let app = NSRunningApplication(processIdentifier: target.pid)
        if app?.isHidden == true { app?.unhide() }

        switch target.locator {
        case .app(let pid):
            if !PrivateAPIs.focus(pid: pid, windowID: 0) { app?.activate() }

        case .window(let pid, let windowID):
            let element = index.element(for: windowID)
            if let element, AX.attribute(element, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let focused = PrivateAPIs.focus(pid: pid, windowID: windowID)
            if let element {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            if !focused { app?.activate() }
            if element == nil { log.error("no AX element cached for window \(windowID)") }
        }
        index.noteActivated(pid: target.pid)
        index.scheduleRefresh()
    }
}
