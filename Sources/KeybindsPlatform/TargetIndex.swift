import AppKit
import KeybindsCore
import Observation
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "index")

/// The cached list of everything the palette can jump to, in recency order.
/// Stale-while-revalidate: readers always get the last snapshot instantly; `refresh()` updates it in the background.
@MainActor
@Observable
public final class TargetIndex {
    public private(set) var targets: [Target] = []
    public private(set) var search = SearchIndex([])

    @ObservationIgnored private let scanner = WindowScanner()
    @ObservationIgnored private let recency = AppRecency()
    @ObservationIgnored private(set) var windowElements: [CGWindowID: AXRef] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let apps = AppInfo.regularApps()
        let scanner = self.scanner
        Task {
            let start = Date()
            let windows = await Task.detached(priority: .userInitiated) { scanner.scan(apps) }.value
            let zOrder = Self.onScreenZOrder()
            self.apply(apps: apps, windows: windows, zOrder: zOrder)
            log.debug("refresh: \(apps.count) apps, \(windows.count) windows in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            self.refreshing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    func element(for windowID: CGWindowID) -> AXUIElement? {
        windowElements[windowID]?.element
    }

    func noteActivated(pid: pid_t) {
        recency.touch(pid)
    }

    // MARK: - Ordering

    private func apply(apps: [AppInfo], windows: [WindowRecord], zOrder: [CGWindowID: Int]) {
        windowElements = Dictionary(windows.map { ($0.windowID, $0.element) }, uniquingKeysWith: { a, _ in a })

        // Sort key: on-screen windows by real z-order (front to back across apps), then everything else
        // by app recency, then by the app's own window order.
        struct Keyed { let target: Target; let key: (Int, Int, Int) }
        var keyed: [Keyed] = []
        let appsWithWindows = Set(windows.map(\.app.pid))

        for w in windows {
            let title = w.title.isEmpty ? w.app.name : w.title
            let subtitle = w.minimized ? "\(w.app.name) · minimized" : w.app.name
            let target = Target(kind: .window, title: title, subtitle: subtitle, appName: w.app.name,
                                bundleID: w.app.bundleID, pid: w.app.pid,
                                locator: .window(pid: w.app.pid, windowID: w.windowID))
            let key = (zOrder[w.windowID] ?? Int.max, recency.rank(w.app.pid), w.axOrder ?? 1000)
            keyed.append(Keyed(target: target, key: key))
        }
        for app in apps where !appsWithWindows.contains(app.pid) {
            let target = Target(kind: .app, title: app.name, subtitle: app.isHidden ? "Application · hidden" : "Application",
                                appName: app.name, bundleID: app.bundleID, pid: app.pid, locator: .app(pid: app.pid))
            keyed.append(Keyed(target: target, key: (Int.max, recency.rank(app.pid), 0)))
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
