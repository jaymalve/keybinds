import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// Double-tap Shift opens and closes the palette.
    public var doubleShiftEnabled: Bool
    public var doubleTap: DoubleTapTiming
    /// Optional key combo that also opens the palette.
    public var paletteCombo: KeyCombo?
    /// While one of these apps is frontmost the combo is released, so the app gets the keystroke (e.g. ⌘K).
    public var comboExcludedBundleIDs: [String]
    /// Tab sources switched off by the user: "chromium", "safari", "terminal". Their apps show windows instead.
    public var disabledTabSources: Set<String>
    /// List installed apps that aren't running, so typing a name can launch them.
    public var showNotRunningApps: Bool
    /// Group browser tabs by website, and fold copies of the same page into one row.
    public var groupTabs: Bool
    /// Files and folders: recently used ones plus a live Spotlight search as you type.
    public var searchFiles: Bool

    public static let `default` = Settings(doubleShiftEnabled: true, doubleTap: .default, paletteCombo: nil,
                                           comboExcludedBundleIDs: [], disabledTabSources: [], showNotRunningApps: true,
                                           groupTabs: false, searchFiles: true)

    public init(doubleShiftEnabled: Bool, doubleTap: DoubleTapTiming, paletteCombo: KeyCombo?,
                comboExcludedBundleIDs: [String], disabledTabSources: Set<String>, showNotRunningApps: Bool,
                groupTabs: Bool, searchFiles: Bool) {
        self.doubleShiftEnabled = doubleShiftEnabled
        self.doubleTap = doubleTap
        self.paletteCombo = paletteCombo
        self.comboExcludedBundleIDs = comboExcludedBundleIDs
        self.disabledTabSources = disabledTabSources
        self.showNotRunningApps = showNotRunningApps
        self.groupTabs = groupTabs
        self.searchFiles = searchFiles
    }

    // Missing keys fall back to defaults, so older settings files keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        doubleShiftEnabled = try c.decodeIfPresent(Bool.self, forKey: .doubleShiftEnabled) ?? d.doubleShiftEnabled
        doubleTap = try c.decodeIfPresent(DoubleTapTiming.self, forKey: .doubleTap) ?? d.doubleTap
        paletteCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .paletteCombo)
        comboExcludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .comboExcludedBundleIDs) ?? d.comboExcludedBundleIDs
        disabledTabSources = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTabSources) ?? d.disabledTabSources
        showNotRunningApps = try c.decodeIfPresent(Bool.self, forKey: .showNotRunningApps) ?? d.showNotRunningApps
        groupTabs = try c.decodeIfPresent(Bool.self, forKey: .groupTabs) ?? d.groupTabs
        searchFiles = try c.decodeIfPresent(Bool.self, forKey: .searchFiles) ?? d.searchFiles
    }
}
