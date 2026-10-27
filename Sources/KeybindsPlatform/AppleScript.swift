import Foundation

/// Runs AppleScript on one serial queue: NSAppleScript shares OSA state between instances, and running
/// scripts on several threads at once mixes up their results (seen in M3). Every script is wrapped in
/// `with timeout`, so a hung app holds the queue for at most a couple of seconds.
final class AppleScriptRunner: @unchecked Sendable {
    struct ScriptError: Error, CustomStringConvertible {
        let number: Int
        let message: String
        /// -1743: the user hasn't allowed (or denied) Automation for this app.
        var isNotAuthorized: Bool { number == -1743 }
        var description: String { "AppleScript error \(number): \(message)" }
    }

    private let queue = DispatchQueue(label: "keybinds.applescript", qos: .userInitiated)
    /// Only touched on `queue`.
    nonisolated(unsafe) private var compiled: [String: NSAppleScript] = [:]

    func run<T: Sendable>(_ source: String, app bundleID: String, cache: Bool = false,
                          parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script = self.script(source, cache: cache)
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    continuation.resume(throwing: ScriptError(
                        number: error[NSAppleScript.errorNumber] as? Int ?? 0,
                        message: error[NSAppleScript.errorMessage] as? String ?? "unknown"))
                } else {
                    continuation.resume(returning: parse(result))
                }
            }
        }
    }

    /// Enumeration scripts are fixed per app, so they're compiled once.
    private func script(_ source: String, cache: Bool) -> NSAppleScript {
        guard cache else { return NSAppleScript(source: source)! }
        if let s = compiled[source] { return s }
        let s = NSAppleScript(source: source)!
        var error: NSDictionary?
        s.compileAndReturnError(&error)
        compiled[source] = s
        return s
    }

    /// Quotes a string for safe interpolation into AppleScript source.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension NSAppleEventDescriptor {
    var items: [NSAppleEventDescriptor] {
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { atIndex($0) }
    }

    /// nil for `missing value`.
    var text: String? {
        descriptorType == typeType && typeCodeValue == 0x6D73_6E67 /* 'msng' */ ? nil : stringValue
    }

    var int: Int { Int(int32Value) }
}
