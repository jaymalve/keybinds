import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// Double-tap Shift opens and closes the palette.
    public var doubleShiftEnabled: Bool
    public var doubleTap: DoubleTapTiming
    /// Optional key combo that also opens the palette.
    public var paletteCombo: KeyCombo?

    public static let `default` = Settings(doubleShiftEnabled: true, doubleTap: .default, paletteCombo: nil)

    public init(doubleShiftEnabled: Bool, doubleTap: DoubleTapTiming, paletteCombo: KeyCombo?) {
        self.doubleShiftEnabled = doubleShiftEnabled
        self.doubleTap = doubleTap
        self.paletteCombo = paletteCombo
    }

    // Missing keys fall back to defaults, so older settings files keep loading as fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        doubleShiftEnabled = try c.decodeIfPresent(Bool.self, forKey: .doubleShiftEnabled) ?? d.doubleShiftEnabled
        doubleTap = try c.decodeIfPresent(DoubleTapTiming.self, forKey: .doubleTap) ?? d.doubleTap
        paletteCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .paletteCombo)
    }
}
