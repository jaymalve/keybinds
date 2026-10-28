import Foundation

public enum TargetKind: String, Sendable {
    case app, window, browserTab, terminalTab, file, folder
}

/// Everything needed to activate a target again.
public enum Locator: Hashable, Sendable {
    case app(pid: Int32)
    case window(pid: Int32, windowID: UInt32)
    /// An installed app that isn't running.
    case launch(path: String)
    // Scripted window/tab ids are kept as text: recent Chrome returns them as text, and comparing
    // them as numbers in AppleScript silently never matches.

    /// Chrome-family tab ids are stable for the tab's lifetime.
    case chromiumTab(bundleID: String, windowID: String, tabID: String)
    /// Safari tabs have no ids: index plus the URL, re-checked before switching.
    case safariTab(windowID: String, tabIndex: Int, url: String?)
    /// The tty identifies a Terminal tab for as long as it's open.
    case terminalTab(windowID: String, tabIndex: Int, tty: String)
    /// A file or folder on disk.
    case file(path: String)
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
    /// Files and folders: when the item arrived in its folder (downloaded, saved, moved in).
    public let added: Date?

    public init(kind: TargetKind, title: String, subtitle: String, appName: String,
                bundleID: String?, pid: Int32, url: String? = nil, locator: Locator, added: Date? = nil) {
        switch locator {
        case .app(let pid): id = "app:\(pid)"
        case .launch(let path): id = "launch:\(path)"
        case .window(_, let windowID): id = "win:\(windowID)"
        case .chromiumTab(let bundleID, _, let tabID): id = "tab:\(bundleID):\(tabID)"
        case .safariTab(let windowID, let tabIndex, _): id = "safari:\(windowID):\(tabIndex)"
        case .terminalTab(_, _, let tty): id = "term:\(tty)"
        case .file(let path): id = "file:\(path)"
        }
        self.url = url
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.locator = locator
        self.added = added
    }
}

extension Target {
    /// Identity that survives restarts, for usage history: pids, window ids and tab ids don't.
    public var historyKey: String {
        switch kind {
        case .browserTab:
            // Ignore #fragments so in-page navigation counts as the same page.
            let page = url.map { $0.split(separator: "#", maxSplits: 1).first.map(String.init) ?? $0 } ?? title
            return "tab:\(page)"
        case .terminalTab:
            return "term:\(title)"
        case .window:
            return "win:\(bundleID ?? appName):\(title)"
        case .app:
            return "app:\(bundleID ?? appName)"
        case .file, .folder:
            return id
        }
    }
}

extension Target {
    /// Same page regardless of #fragment or a trailing slash; nil for anything that isn't a browser tab.
    public var pageKey: String? {
        guard kind == .browserTab, let url, !url.isEmpty else { return nil }
        var page = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
        if page.hasSuffix("/") { page.removeLast() }
        return page
    }

    /// The tab's website, without "www.", for grouping.
    public var siteKey: String? {
        guard kind == .browserTab, let host = url.flatMap({ URL(string: $0)?.host() }), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Target {
    public var isFileSystem: Bool { kind == .file || kind == .folder }
}
