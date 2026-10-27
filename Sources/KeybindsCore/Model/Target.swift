import Foundation

public enum TargetKind: String, Sendable {
    case app, window, browserTab, terminalTab
}

/// Everything needed to activate a target again.
public enum Locator: Hashable, Sendable {
    case app(pid: Int32)
    case window(pid: Int32, windowID: UInt32)
    // Scripted window/tab ids are kept as text: recent Chrome returns them as text, and comparing
    // them as numbers in AppleScript silently never matches.

    /// Chrome-family tab ids are stable for the tab's lifetime.
    case chromiumTab(bundleID: String, windowID: String, tabID: String)
    /// Safari tabs have no ids: index plus the URL, re-checked before switching.
    case safariTab(windowID: String, tabIndex: Int, url: String?)
    /// The tty identifies a Terminal tab for as long as it's open.
    case terminalTab(windowID: String, tabIndex: Int, tty: String)
}

/// One row in the palette: something you can jump to.
public struct Target: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: TargetKind
    public let title: String
    public let subtitle: String
    public let appName: String
    public let bundleID: String?
    public let pid: Int32
    public let url: String?
    public let locator: Locator

    public init(kind: TargetKind, title: String, subtitle: String, appName: String,
                bundleID: String?, pid: Int32, url: String? = nil, locator: Locator) {
        switch locator {
        case .app(let pid): id = "app:\(pid)"
        case .window(_, let windowID): id = "win:\(windowID)"
        case .chromiumTab(let bundleID, _, let tabID): id = "tab:\(bundleID):\(tabID)"
        case .safariTab(let windowID, let tabIndex, _): id = "safari:\(windowID):\(tabIndex)"
        case .terminalTab(_, _, let tty): id = "term:\(tty)"
        }
        self.url = url
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.locator = locator
    }
}
