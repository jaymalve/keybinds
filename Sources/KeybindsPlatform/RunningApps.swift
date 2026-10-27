import AppKit

/// A Sendable snapshot of a running app.
public struct AppInfo: Sendable, Hashable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let isHidden: Bool

    @MainActor
    static func regularApps() -> [AppInfo] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated }
            .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                           bundleID: $0.bundleIdentifier, isHidden: $0.isHidden) }
    }
}

/// Most-recently-activated-first order of apps, tracked from NSWorkspace notifications.
@MainActor
final class AppRecency {
    private(set) var order: [pid_t] = []
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { order = [front.processIdentifier] }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.touch(pid) }
            }
        }
    }

    func touch(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    /// Lower is more recent. Apps never seen activating sort after all seen ones.
    func rank(_ pid: pid_t) -> Int {
        order.firstIndex(of: pid) ?? order.count
    }
}
