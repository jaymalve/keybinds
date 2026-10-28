import Foundation
import OSLog

private let tabLog = Logger(subsystem: "com.jaymalve.keybinds", category: "tabs")

/// One scripted window and its tabs, as the app's AppleScript dictionary reports them.
struct ScriptWindow: Sendable {
    let id: String
    /// Window title; used to match the window to its AX element / CGWindowID.
    let name: String
    /// 1-based index of the selected tab.
    let activeIndex: Int
    let tabs: [ScriptTab]
}

struct ScriptTab: Sendable {
    let index: Int
    let chromiumID: String?
    let title: String
    let url: String?
    let tty: String?
}

enum TabSource: String, Sendable {
    case chromium, safari, terminal

    static func forBundle(_ bundleID: String?) -> TabSource? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
             "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
            return .chromium
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.apple.Terminal":
            return .terminal
        default:
            return nil
        }
    }
}

/// Reads tabs from scriptable browsers and Terminal with one batched Apple Event per app (spike M0.1: 3–33 ms).
final class TabScanner: Sendable {
    private let runner = AppleScriptRunner()

    /// Only call for apps that are running: `tell application` launches apps that aren't.
    func scan(_ source: TabSource, bundleID: String) async throws -> [ScriptWindow] {
        switch source {
        case .chromium: try await scanChromium(bundleID)
        case .safari: try await scanSafari(bundleID)
        case .terminal: try await scanTerminal(bundleID)
        }
    }

    // MARK: Enumerate

    private func scanChromium(_ bundleID: String) async throws -> [ScriptWindow] {
        let source = """
        with timeout of 2 seconds
            tell application id \(AppleScriptRunner.quoted(bundleID))
                return {id of windows, name of windows, active tab index of windows, id of tabs of windows, title of tabs of windows, URL of tabs of windows}
            end tell
        end timeout
        """
        return try await runner.run(source, app: bundleID, cache: true) { r in
            let ids = r.atIndex(1)?.items ?? [], names = r.atIndex(2)?.items ?? [], active = r.atIndex(3)?.items ?? []
            let tabIDs = r.atIndex(4)?.items ?? [], titles = r.atIndex(5)?.items ?? [], urls = r.atIndex(6)?.items ?? []
            return ids.indices.map { w in
                let tIDs = tabIDs[safe: w]?.items ?? [], tTitles = titles[safe: w]?.items ?? [], tURLs = urls[safe: w]?.items ?? []
                let tabs = tIDs.indices.map { t in
                    ScriptTab(index: t + 1, chromiumID: tIDs[t].text, title: tTitles[safe: t]?.text ?? "",
                              url: tURLs[safe: t]?.text, tty: nil)
                }
                return ScriptWindow(id: ids[w].text ?? "", name: names[safe: w]?.text ?? "",
                                    activeIndex: active[safe: w]?.int ?? 1, tabs: tabs)
            }
        }
    }

    private func scanSafari(_ bundleID: String) async throws -> [ScriptWindow] {
        // Non-browser windows (Settings etc.) have no tabs and throw; skip them.
        let source = """
        with timeout of 2 seconds
            tell application id \(AppleScriptRunner.quoted(bundleID))
                set out to {}
                repeat with w in windows
                    try
                        set end of out to {id of w, name of w, index of current tab of w, name of tabs of w, URL of tabs of w}
                    on error e
                        set end of out to {-1, e}
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
        return try await runner.run(source, app: bundleID, cache: true) { r in
            r.items.compactMap { w in
                guard w.atIndex(1)?.text != "-1" else {
                    tabLog.debug("Safari window skipped: \(w.atIndex(2)?.text ?? "?", privacy: .public)")
                    return nil
                }
                let names = w.atIndex(4)?.items ?? [], urls = w.atIndex(5)?.items ?? []
                let tabs = names.indices.map { t in
                    ScriptTab(index: t + 1, chromiumID: nil, title: names[t].text ?? "",
                              url: urls[safe: t]?.text, tty: nil)
                }
                return ScriptWindow(id: w.atIndex(1)?.text ?? "", name: w.atIndex(2)?.text ?? "",
                                    activeIndex: w.atIndex(3)?.int ?? 1, tabs: tabs)
            }
        }
    }

    private func scanTerminal(_ bundleID: String) async throws -> [ScriptWindow] {
        let source = """
        with timeout of 2 seconds
            tell application id \(AppleScriptRunner.quoted(bundleID))
                return {id of windows, name of windows, tty of tabs of windows, custom title of tabs of windows, selected of tabs of windows}
            end tell
        end timeout
        """
        return try await runner.run(source, app: bundleID, cache: true) { r in
            let ids = r.atIndex(1)?.items ?? [], names = r.atIndex(2)?.items ?? []
            let ttys = r.atIndex(3)?.items ?? [], titles = r.atIndex(4)?.items ?? [], selected = r.atIndex(5)?.items ?? []
            return ids.indices.map { w in
                let tTTYs = ttys[safe: w]?.items ?? [], tTitles = titles[safe: w]?.items ?? []
                let tSelected = selected[safe: w]?.items ?? []
                let tabs = tTTYs.indices.map { t in
                    ScriptTab(index: t + 1, chromiumID: nil, title: tTitles[safe: t]?.text ?? "", url: nil, tty: tTTYs[t].text)
                }
                let active = (tSelected.firstIndex { $0.booleanValue } ?? 0) + 1
                return ScriptWindow(id: ids[w].text ?? "", name: names[safe: w]?.text ?? "", activeIndex: active, tabs: tabs)
            }
        }
    }

    // MARK: Select

    /// Makes the tab current inside its window. Bringing the window forward is the Activator's job.
    /// Returns false if the window or tab no longer exists.
    func select(_ locator: TabSelector, bundleID: String) async throws -> Bool {
        let body: String
        switch locator {
        case .chromium(let windowID, let tabID):
            body = """
            \(Self.findWindow(windowID))
            set i to 1
            repeat with t in tabs of w
                if (id of t as text) is \(AppleScriptRunner.quoted(tabID)) then
                    set active tab index of w to i
                    return true
                end if
                set i to i + 1
            end repeat
            return false
            """
        case .safari(let windowID, let tabIndex, let url):
            // Tabs may have moved since the scan: prefer the URL, fall back to the index.
            let match = url.map { "if URL of tab i of w is \(AppleScriptRunner.quoted($0)) then" } ?? "if i is \(tabIndex) then"
            body = """
            \(Self.findWindow(windowID))
            repeat with i from 1 to count of tabs of w
                \(match)
                    set current tab of w to tab i of w
                    return true
                end if
            end repeat
            return false
            """
        case .terminal(let windowID, let tty):
            body = """
            \(Self.findWindow(windowID))
            repeat with t in tabs of w
                if tty of t is \(AppleScriptRunner.quoted(tty)) then
                    set selected tab of w to t
                    return true
                end if
            end repeat
            return false
            """
        }
        return try await runner.run(Self.wrap(body, bundleID), app: bundleID) { $0.booleanValue }
    }

    /// Closes a browser tab in the background. Returns false if it no longer exists.
    /// Terminal can't close a tab via AppleScript; `Closer` uses its Close Tab menu item instead.
    func close(_ locator: TabSelector, bundleID: String) async throws -> Bool {
        let body: String
        switch locator {
        case .chromium(let windowID, let tabID):
            body = """
            \(Self.findWindow(windowID))
            repeat with t in tabs of w
                if (id of t as text) is \(AppleScriptRunner.quoted(tabID)) then
                    close t
                    return true
                end if
            end repeat
            return false
            """
        case .safari(let windowID, let tabIndex, let url):
            // Check the scanned index first (copies of one page share a URL), then look by URL.
            let check = url.map { "URL of tab i of w is \(AppleScriptRunner.quoted($0))" } ?? "true"
            let search = url.map { """
                repeat with j from 1 to count of tabs of w
                    if URL of tab j of w is \(AppleScriptRunner.quoted($0)) then
                        close tab j of w
                        return true
                    end if
                end repeat
                """ } ?? ""
            body = """
            \(Self.findWindow(windowID))
            set i to \(tabIndex)
            if i ≤ (count of tabs of w) then
                if \(check) then
                    close tab i of w
                    return true
                end if
            end if
            \(search)
            return false
            """
        case .terminal:
            return false
        }
        return try await runner.run(Self.wrap(body, bundleID), app: bundleID) { $0.booleanValue }
    }

    /// Fallback when the window's CGWindowID is unknown: raise it inside the app via AppleScript.
    func raise(windowID: String, bundleID: String) async throws {
        let body = """
        \(Self.findWindow(windowID))
        set index of w to 1
        return true
        """
        _ = try await runner.run(Self.wrap(body, bundleID), app: bundleID) { $0.booleanValue }
    }

    /// Sets `w` to the window whose id, as text, matches; returns false from the script if there's none.
    private static func findWindow(_ windowID: String) -> String {
        """
        set w to missing value
        repeat with x in windows
            if (id of x as text) is \(AppleScriptRunner.quoted(windowID)) then
                set w to contents of x
                exit repeat
            end if
        end repeat
        if w is missing value then return false
        """
    }

    private static func wrap(_ body: String, _ bundleID: String) -> String {
        """
        with timeout of 2 seconds
            tell application id \(AppleScriptRunner.quoted(bundleID))
        \(body)
            end tell
        end timeout
        """
    }
}

enum TabSelector: Sendable {
    case chromium(windowID: String, tabID: String)
    case safari(windowID: String, tabIndex: Int, url: String?)
    case terminal(windowID: String, tty: String)
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
