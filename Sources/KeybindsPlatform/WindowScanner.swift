import ApplicationServices
import CoreGraphics
import Foundation

struct WindowRecord: Sendable {
    let app: AppInfo
    let windowID: CGWindowID
    let title: String
    let minimized: Bool
    /// Position in the app's own kAXWindows list (front to back on the current Space), or nil if only
    /// found by the remote-token scan (other Space).
    let axOrder: Int?
    let element: AXRef
}

/// Finds every window of every app on all Spaces: plain kAXWindows (current Space, z-ordered) plus the
/// remote-token brute force for other Spaces (spike M0.2), then drops hidden panels that belong to no Space.
final class WindowScanner: @unchecked Sendable {
    private let lock = NSLock()
    /// Apps that recently timed out are skipped until this time; their last results are reused.
    private var backoffUntil: [pid_t: Date] = [:]
    private var lastResults: [pid_t: [WindowRecord]] = [:]

    private static let slowScan: TimeInterval = 0.5
    private static let backoff: TimeInterval = 30
    private static let remoteBudget: TimeInterval = 0.1
    private static let remoteMaxID: UInt64 = 1000

    init() {
        AX.setGlobalTimeout(0.25)
    }

    /// Scans apps in parallel. Never call on the main thread.
    func scan(_ apps: [AppInfo]) -> [WindowRecord] {
        guard AXIsProcessTrusted() else { return [] }
        // Each iteration writes only its own slot.
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<[WindowRecord]>.allocate(capacity: apps.count)
        results.initialize(repeating: [])
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            results[i] = scanApp(apps[i])
        }
        let all = results.flatMap { $0 }

        // Keep windows that are on some Space, minimized, or belong to a hidden app.
        guard let onSpace = PrivateAPIs.windowsOnAnySpace(all.map(\.windowID)) else { return all }
        return all.filter { onSpace.contains($0.windowID) || $0.minimized || $0.app.isHidden }
    }

    private func scanApp(_ app: AppInfo) -> [WindowRecord] {
        let now = Date()
        lock.lock()
        let skip = (backoffUntil[app.pid] ?? .distantPast) > now
        let cached = lastResults[app.pid] ?? []
        lock.unlock()
        if skip { return cached }

        let start = Date()
        let axApp = AXUIElementCreateApplication(app.pid)
        let plain: [AXUIElement] = AX.attribute(axApp, kAXWindowsAttribute) ?? []

        var seen = Set<CGWindowID>()
        var records: [WindowRecord] = []
        for (order, el) in plain.enumerated() {
            if let r = record(el, app: app, axOrder: order), seen.insert(r.windowID).inserted { records.append(r) }
        }
        for el in remoteWindows(pid: app.pid) {
            if let r = record(el, app: app, axOrder: nil), seen.insert(r.windowID).inserted { records.append(r) }
        }

        let slow = Date().timeIntervalSince(start) > Self.slowScan
        lock.lock()
        lastResults[app.pid] = records
        backoffUntil[app.pid] = slow ? now.addingTimeInterval(Self.backoff) : nil
        lock.unlock()
        return records
    }

    private func record(_ el: AXUIElement, app: AppInfo, axOrder: Int?) -> WindowRecord? {
        let subrole: String? = AX.attribute(el, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole,
              let id = AX.windowID(el) else { return nil }
        let title: String = AX.attribute(el, kAXTitleAttribute) ?? ""
        let minimized: Bool = AX.attribute(el, kAXMinimizedAttribute) ?? false
        return WindowRecord(app: app, windowID: id, title: title, minimized: minimized,
                            axOrder: axOrder, element: AXRef(element: el))
    }

    /// Token layout: pid (Int32) | 0 (Int32) | 'coco' (Int32) | element id (UInt64).
    private func remoteWindows(pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var found: [AXUIElement] = []
        let start = Date()
        for id in 0..<Self.remoteMaxID {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            if let el = PrivateAPIs.axElement(remoteToken: token) {
                let role: String? = AX.attribute(el, kAXRoleAttribute)
                if role == kAXWindowRole { found.append(el) }
            }
            if Date().timeIntervalSince(start) > Self.remoteBudget { break }
        }
        return found
    }
}
