import AppKit
import ApplicationServices
import KeybindsCore
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "activate")

/// Brings a target to the front: selects the tab, unminimizes, switches Space, focuses the exact window.
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
            focusWindow(pid: pid, windowID: windowID, app: app)

        case .chromiumTab(let bundleID, let windowID, let tabID):
            activateTab(.chromium(windowID: windowID, tabID: tabID), scriptWindowID: windowID, bundleID: bundleID, target: target, app: app)

        case .safariTab(let windowID, let tabIndex, let url):
            activateTab(.safari(windowID: windowID, tabIndex: tabIndex, url: url), scriptWindowID: windowID,
                        bundleID: target.bundleID ?? "com.apple.Safari", target: target, app: app)

        case .terminalTab(let windowID, _, let tty):
            activateTab(.terminal(windowID: windowID, tty: tty), scriptWindowID: windowID,
                        bundleID: target.bundleID ?? "com.apple.Terminal", target: target, app: app)
        }
        index.noteActivated(pid: target.pid)
        index.scheduleRefresh()
    }

    /// Select the tab first, then focus its window. If the window couldn't be matched to a CGWindowID,
    /// raise it through AppleScript and activate the app instead.
    private func activateTab(_ selector: TabSelector, scriptWindowID: String, bundleID: String,
                             target: Target, app: NSRunningApplication?) {
        let cgWindow = index.cgWindowID(pid: target.pid, scriptWindowID: scriptWindowID)
        let scanner = index.tabScanner
        Task {
            do {
                if try await !scanner.select(selector, bundleID: bundleID) {
                    log.error("tab not found for \(target.id, privacy: .public); it may have been closed")
                }
            } catch {
                log.error("selecting tab failed: \(String(describing: error), privacy: .public)")
            }
            if let cgWindow {
                focusWindow(pid: target.pid, windowID: cgWindow, app: app)
            } else {
                log.notice("no CGWindowID for scripted window \(scriptWindowID); falling back to AppleScript raise")
                try? await scanner.raise(windowID: scriptWindowID, bundleID: bundleID)
                if !PrivateAPIs.focus(pid: target.pid, windowID: 0) { app?.activate() }
            }
        }
    }

    private func focusWindow(pid: pid_t, windowID: CGWindowID, app: NSRunningApplication?) {
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
}
