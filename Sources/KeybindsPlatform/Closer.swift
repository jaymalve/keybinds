import AppKit
import ApplicationServices
import KeybindsCore
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "close")

/// Closes tabs and windows and quits apps, without switching to them.
@MainActor
public struct Closer {
    let index: TargetIndex

    public init(index: TargetIndex) {
        self.index = index
    }

    /// Shells don't count as "something running" in a Terminal tab.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "nu", "login", "-zsh", "-bash"]

    /// The process running in a Terminal tab, if it's something other than an idle shell (Terminal asks
    /// before closing those, so the tab has to be on screen).
    public func busyProcess(_ target: Target) -> String? {
        guard case .terminalTab(_, _, let tty) = target.locator,
              let process = index.terminalProcess(tty: tty), !Self.shells.contains(process) else { return nil }
        return process
    }

    /// Closes one tab or window. Returns false if it couldn't (already gone, or not closable).
    public func close(_ target: Target) async -> Bool {
        let scanner = index.tabScanner
        do {
            switch target.locator {
            case .chromiumTab(let bundleID, let windowID, let tabID):
                return try await scanner.close(.chromium(windowID: windowID, tabID: tabID), bundleID: bundleID)
            case .safariTab(let windowID, let tabIndex, let url):
                return try await scanner.close(.safari(windowID: windowID, tabIndex: tabIndex, url: url),
                                               bundleID: target.bundleID ?? "com.apple.Safari")
            case .terminalTab(let windowID, _, let tty):
                // Select the tab and bring its window to the front of Terminal, then use Close Tab (⌘W).
                let bundleID = target.bundleID ?? "com.apple.Terminal"
                guard try await scanner.select(.terminal(windowID: windowID, tty: tty), bundleID: bundleID) else { return false }
                try await scanner.raise(windowID: windowID, bundleID: bundleID)
                guard let item = AX.menuItem(pid: target.pid, commandKey: "W") else {
                    log.error("Terminal has no ⌘W menu item")
                    return false
                }
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            case .window(_, let windowID):
                guard let window = index.element(for: windowID),
                      let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
                return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            case .app, .launch:
                return false
            }
        } catch {
            log.error("closing \(target.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Asks the app to quit; it may still ask about unsaved work.
    public func quit(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }
}
