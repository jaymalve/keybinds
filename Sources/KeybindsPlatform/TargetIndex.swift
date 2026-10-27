import AppKit
import KeybindsCore
import Observation
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "index")

/// The cached list of everything the palette can jump to, in recency order.
/// Stale-while-revalidate: readers always get the last snapshot instantly; `refresh()` updates it in the
/// background. Windows and each app's tabs are scanned independently and merged as each one finishes.
@MainActor
@Observable
public final class TargetIndex {
    public private(set) var targets: [Target] = []
    public private(set) var search = SearchIndex([])

    @ObservationIgnored let tabScanner = TabScanner()
    @ObservationIgnored private let windowScanner = WindowScanner()
    @ObservationIgnored private let recency = AppRecency()

    // Latest results from each source.
    @ObservationIgnored private var apps: [AppInfo] = []
    @ObservationIgnored private var windows: [WindowRecord] = []
    @ObservationIgnored private var zOrder: [CGWindowID: Int] = [:]
    @ObservationIgnored private var tabs: [pid_t: [ScriptWindow]] = [:]
    @ObservationIgnored private var terminalLabels: [String: TerminalLabels.Label] = [:]

    @ObservationIgnored private var windowElements: [CGWindowID: AXRef] = [:]
    /// (pid, scripted window id) → CGWindowID, matched by title.
    @ObservationIgnored private var scriptWindowMap: [ScriptWindowKey: CGWindowID] = [:]

    @ObservationIgnored private var scanningWindows = false
    @ObservationIgnored private var rescanWindows = false
    @ObservationIgnored private var scanningTabs = Set<pid_t>()
    /// Apps whose Automation permission was denied: not asked again until relaunch.
    @ObservationIgnored private var tabsDenied = Set<String>()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    struct ScriptWindowKey: Hashable {
        let pid: pid_t
        let windowID: String
    }

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    /// Coalesces bursts of workspace notifications.
    public func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    public func refresh() {
        let apps = AppInfo.regularApps()
        self.apps = apps
        refreshWindows(apps)
        for app in apps {
            guard let bundleID = app.bundleID, let source = TabSource.forBundle(bundleID),
                  !tabsDenied.contains(bundleID) else { continue }
            refreshTabs(app, bundleID: bundleID, source: source)
        }
    }

    private func refreshWindows(_ apps: [AppInfo]) {
        guard !scanningWindows else { rescanWindows = true; return }
        scanningWindows = true
        let scanner = windowScanner
        Task {
            let start = Date()
            let windows = await Task.detached(priority: .userInitiated) { scanner.scan(apps) }.value
            self.windows = windows
            self.zOrder = Self.onScreenZOrder()
            self.windowElements = Dictionary(windows.map { ($0.windowID, $0.element) }, uniquingKeysWith: { a, _ in a })
            self.rebuild()
            log.debug("windows: \(apps.count) apps, \(windows.count) windows in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            self.scanningWindows = false
            if self.rescanWindows {
                self.rescanWindows = false
                self.refreshWindows(self.apps)
            }
        }
    }

    /// One in-flight scan per app; a slow app never delays the others.
    private func refreshTabs(_ app: AppInfo, bundleID: String, source: TabSource) {
        guard scanningTabs.insert(app.pid).inserted else { return }
        let scanner = tabScanner
        Task {
            let start = Date()
            do {
                let scripted = try await scanner.scan(source, bundleID: bundleID)
                if source == .terminal {
                    let ttys = Set(scripted.flatMap { $0.tabs.compactMap(\.tty) })
                    self.terminalLabels = await Task.detached { TerminalLabels.labels(for: ttys) }.value
                }
                self.tabs[app.pid] = scripted
                log.debug("tabs: \(app.name, privacy: .public) \(scripted.reduce(0) { $0 + $1.tabs.count }) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            } catch let error as AppleScriptRunner.ScriptError where error.isNotAuthorized {
                log.notice("Automation denied for \(bundleID, privacy: .public); showing its windows instead")
                self.tabsDenied.insert(bundleID)
                self.tabs[app.pid] = nil
            } catch {
                log.error("tabs: \(app.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            self.scanningTabs.remove(app.pid)
            self.rebuild()
        }
    }

    func element(for windowID: CGWindowID) -> AXUIElement? {
        windowElements[windowID]?.element
    }

    func cgWindowID(pid: pid_t, scriptWindowID: String) -> CGWindowID? {
        scriptWindowMap[ScriptWindowKey(pid: pid, windowID: scriptWindowID)]
    }

    func noteActivated(pid: pid_t) {
        recency.touch(pid)
    }

    // MARK: - Merge and order

    private func rebuild() {
        let running = Set(apps.map(\.pid))
        tabs = tabs.filter { running.contains($0.key) }
        scriptWindowMap = matchScriptWindows()

        // Sort key: on-screen windows by real z-order (front to back across apps), then by app recency,
        // then by position within the app.
        struct Keyed { let target: Target; let key: (Int, Int, Int) }
        var keyed: [Keyed] = []
        var windowKeys: [CGWindowID: (Int, Int, Int)] = [:]

        for w in windows {
            let key = (zOrder[w.windowID] ?? Int.max, recency.rank(w.app.pid), w.axOrder ?? 1000)
            windowKeys[w.windowID] = key
            // Apps with tabs show their tabs instead of their windows.
            guard tabs[w.app.pid] == nil else { continue }
            let title = w.title.isEmpty ? w.app.name : w.title
            let subtitle = w.minimized ? "\(w.app.name) · minimized" : w.app.name
            keyed.append(Keyed(target: Target(kind: .window, title: title, subtitle: subtitle, appName: w.app.name,
                                              bundleID: w.app.bundleID, pid: w.app.pid,
                                              locator: .window(pid: w.app.pid, windowID: w.windowID)), key: key))
        }

        let appsWithEntries = Set(windows.map(\.app.pid)).union(tabs.keys)
        for app in apps {
            if let scripted = tabs[app.pid] {
                for (wi, sw) in scripted.enumerated() {
                    let cg = scriptWindowMap[ScriptWindowKey(pid: app.pid, windowID: sw.id)]
                    let windowKey = cg.flatMap { windowKeys[$0] } ?? (Int.max, recency.rank(app.pid), 1000 + wi)
                    for tab in sw.tabs {
                        guard let target = tabTarget(tab, in: sw, app: app) else { continue }
                        // The selected tab stands in for its window; the rest follow, in tab order.
                        let key = tab.index == sw.activeIndex
                            ? windowKey
                            : (Int.max, recency.rank(app.pid), 2000 + windowKey.2 * 200 + tab.index)
                        keyed.append(Keyed(target: target, key: key))
                    }
                }
            } else if !appsWithEntries.contains(app.pid) {
                keyed.append(Keyed(target: Target(kind: .app, title: app.name,
                                                  subtitle: app.isHidden ? "Application · hidden" : "Application",
                                                  appName: app.name, bundleID: app.bundleID, pid: app.pid,
                                                  locator: .app(pid: app.pid)),
                                   key: (Int.max, recency.rank(app.pid), 0)))
            }
        }

        keyed.sort { $0.key < $1.key }
        var ordered = keyed.map(\.target)

        // The first entry is where you are right now; move it last so Enter means "go back" (like ⌘Tab).
        if let first = ordered.first, first.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            ordered.append(ordered.removeFirst())
        }

        if ordered != targets {
            targets = ordered
            search = SearchIndex(ordered)
        }
    }

    private func tabTarget(_ tab: ScriptTab, in window: ScriptWindow, app: AppInfo) -> Target? {
        guard let bundleID = app.bundleID else { return nil }
        if let tty = tab.tty {
            let label = terminalLabels[tty]
            let title = [label?.process, label?.cwd].compactMap { $0 }.joined(separator: " — ")
            let custom = tab.title.isEmpty ? nil : tab.title
            return Target(kind: .terminalTab, title: title.isEmpty ? (custom ?? tty) : title,
                          subtitle: [app.name, custom].compactMap { $0 }.joined(separator: " · "),
                          appName: app.name, bundleID: bundleID, pid: app.pid,
                          locator: .terminalTab(windowID: window.id, tabIndex: tab.index, tty: tty))
        }
        let host = tab.url.flatMap { URL(string: $0)?.host() }
        let subtitle = [host, app.name].compactMap { $0 }.joined(separator: " · ")
        let title = tab.title.isEmpty ? (tab.url ?? "Untitled") : tab.title
        let locator: Locator
        if let id = tab.chromiumID {
            locator = .chromiumTab(bundleID: bundleID, windowID: window.id, tabID: id)
        } else {
            locator = .safariTab(windowID: window.id, tabIndex: tab.index, url: tab.url)
        }
        return Target(kind: .browserTab, title: title, subtitle: subtitle, appName: app.name,
                      bundleID: bundleID, pid: app.pid, url: tab.url, locator: locator)
    }

    /// Matches scripted windows to AX windows of the same app by title. A browser's AX title is the
    /// scripted name plus a suffix (" - Google Chrome - Profile"), so prefix matching is enough.
    private func matchScriptWindows() -> [ScriptWindowKey: CGWindowID] {
        var map: [ScriptWindowKey: CGWindowID] = [:]
        let byPid = Dictionary(grouping: windows, by: \.app.pid)
        for (pid, scripted) in tabs {
            var unused = byPid[pid] ?? []
            for sw in scripted where !sw.name.isEmpty {
                guard let i = unused.firstIndex(where: { $0.title == sw.name })
                        ?? unused.firstIndex(where: { $0.title.hasPrefix(sw.name) }) else { continue }
                map[ScriptWindowKey(pid: pid, windowID: sw.id)] = unused[i].windowID
                unused.remove(at: i)
            }
        }
        return map
    }

    /// Front-to-back order of normal windows on the current Space. Window numbers and owners only,
    /// so no Screen Recording permission is needed.
    private static func onScreenZOrder() -> [CGWindowID: Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let id = w[kCGWindowNumber as String] as? CGWindowID, order[id] == nil { order[id] = order.count }
        }
        return order
    }
}
