import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// Tapping ⌥ opens and closes the palette.
    public var optionTapEnabled: Bool
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
    /// Optional key combo that puts click labels on the front window (the palette's Tab does the same).
    public var clickCombo: KeyCombo?
    /// Holding this key alone shows the click labels; letting go hides them.
    public var clickHoldKey: HoldKey

    public static let `default` = Settings(optionTapEnabled: true, paletteCombo: nil,
                                           comboExcludedBundleIDs: [], disabledTabSources: [], showNotRunningApps: true,
                                           groupTabs: false, searchFiles: true, clickCombo: nil,
                                           clickHoldKey: .option)

    public init(optionTapEnabled: Bool, paletteCombo: KeyCombo?,
                comboExcludedBundleIDs: [String], disabledTabSources: Set<String>, showNotRunningApps: Bool,
                groupTabs: Bool, searchFiles: Bool, clickCombo: KeyCombo?, clickHoldKey: HoldKey) {
        self.optionTapEnabled = optionTapEnabled
        self.paletteCombo = paletteCombo
        self.comboExcludedBundleIDs = comboExcludedBundleIDs
        self.disabledTabSources = disabledTabSources
        self.showNotRunningApps = showNotRunningApps
        self.groupTabs = groupTabs
        self.searchFiles = searchFiles
        self.clickCombo = clickCombo
        self.clickHoldKey = clickHoldKey
    }

    // Missing keys fall back to defaults, so older settings files keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        optionTapEnabled = try c.decodeIfPresent(Bool.self, forKey: .optionTapEnabled) ?? d.optionTapEnabled
        paletteCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .paletteCombo)
        comboExcludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .comboExcludedBundleIDs) ?? d.comboExcludedBundleIDs
        disabledTabSources = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTabSources) ?? d.disabledTabSources
        showNotRunningApps = try c.decodeIfPresent(Bool.self, forKey: .showNotRunningApps) ?? d.showNotRunningApps
        groupTabs = try c.decodeIfPresent(Bool.self, forKey: .groupTabs) ?? d.groupTabs
        searchFiles = try c.decodeIfPresent(Bool.self, forKey: .searchFiles) ?? d.searchFiles
        clickCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .clickCombo)
        clickHoldKey = try c.decodeIfPresent(HoldKey.self, forKey: .clickHoldKey) ?? d.clickHoldKey
    }
}

/// The key you hold to show click labels.
public enum HoldKey: String, Codable, Sendable, CaseIterable {
    /// Either ⌥.
    case option
    case rightCommand
    case off
}
