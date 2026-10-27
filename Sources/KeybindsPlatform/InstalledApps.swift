import Foundation

/// An app installed on disk, for launching apps that aren't running.
struct InstalledApp: Sendable {
    let name: String
    let bundleID: String?
    let path: String

    /// Standard application folders, one level deep plus Utilities. Background only (~tens of ms).
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                let path = dir + "/" + entry
                let bundleID = Bundle(path: path)?.bundleIdentifier
                guard seen.insert(bundleID ?? path).inserted else { continue }
                let name = (fm.displayName(atPath: path) as NSString).deletingPathExtension
                apps.append(InstalledApp(name: name, bundleID: bundleID, path: path))
            }
        }
        return apps
    }
}
