import ApplicationServices
import CoreGraphics
import Darwin

// Private APIs, all used by AltTab for years. Everything here is resolved at runtime with dlsym,
// so a macOS update that removes a symbol degrades a feature instead of crashing at launch.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum PrivateAPIs {
    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ names: String..., as type: T.Type) -> T? {
        for name in names {
            if let p = dlsym(skyLight, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {  // RTLD_DEFAULT
                return unsafeBitCast(p, to: type)
            }
        }
        return nil
    }

    // MARK: AX

    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let createWithRemoteToken = symbol("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)

    static func axElement(remoteToken: Data) -> AXUIElement? {
        createWithRemoteToken?(remoteToken as CFData)?.takeRetainedValue()
    }

    // MARK: Spaces

    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias CopySpacesForWindows = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let mainConnectionID = symbol("SLSMainConnectionID", "CGSMainConnectionID", as: MainConnectionID.self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", "CGSCopySpacesForWindows", as: CopySpacesForWindows.self)

    /// Windows that belong to at least one Space. Hidden/ordered-out panels belong to none.
    /// Returns nil when the API is unavailable, so callers can skip the filter.
    static func windowsOnAnySpace(_ ids: [CGWindowID]) -> Set<CGWindowID>? {
        guard let connection = mainConnectionID?(), let copy = copySpacesForWindows else { return nil }
        var result = Set<CGWindowID>()
        for id in ids {  // one call per window: the batched form doesn't say which window is on which Space
            let spaces = copy(connection, 0x7 /* all Spaces */, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
            if let spaces, CFArrayGetCount(spaces) > 0 { result.insert(id) }
        }
        return result
    }

    // MARK: Focus

    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecordTo.self)

    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)

    /// Brings `pid` to the front and makes `windowID` its key window, switching Spaces if needed.
    /// Pass windowID 0 to just activate the app with all its windows. Returns false if unavailable.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let mode: UInt32 = windowID == 0 ? 0x100 /* all windows */ : 0x200 /* user generated */
        guard setFrontProcess(&psn, windowID, mode) == .success else { return false }
        if windowID != 0 { makeKeyWindow(&psn, windowID) }
        return true
    }

    /// Synthesizes the window-server event that makes a specific window key (AltTab's makeKeyWindow).
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
    }
}
