import Foundation

public enum TargetKind: String, Sendable {
    case app, window
}

/// Everything needed to activate a target again.
public enum Locator: Hashable, Sendable {
    case app(pid: Int32)
    case window(pid: Int32, windowID: UInt32)
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
    public let locator: Locator

    public init(kind: TargetKind, title: String, subtitle: String, appName: String,
                bundleID: String?, pid: Int32, locator: Locator) {
        switch locator {
        case .app(let pid): id = "app:\(pid)"
        case .window(_, let windowID): id = "win:\(windowID)"
        }
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.locator = locator
    }
}
