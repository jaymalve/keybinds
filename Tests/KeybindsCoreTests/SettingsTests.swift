import Foundation
import KeybindsCore

func settingsTests() {
    print("Settings")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keybinds-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    test("missing file loads defaults") {
        let store = SettingsStore(url: dir.appendingPathComponent("missing.json"))
        expect(try store.load(), Settings.default)
    }
    test("save then load round-trips") {
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        var s = Settings.default
        s.paletteCombo = KeyCombo(keyCode: 40, modifiers: [.command])
        s.doubleTap.maxGap = 0.4
        try store.save(s)
        expect(try store.load(), s)
    }
    test("partial file fills in defaults") {
        let url = dir.appendingPathComponent("partial.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"paletteCombo": {"keyCode": 40, "modifiers": ["command"]}}"#.utf8).write(to: url)
        let s = try SettingsStore(url: url).load()
        expect(s.doubleShiftEnabled, true)
        expect(s.doubleTap, DoubleTapTiming.default)
        expect(s.paletteCombo, KeyCombo(keyCode: 40, modifiers: [.command]))
    }
    test("malformed file throws instead of resetting") {
        let url = dir.appendingPathComponent("bad.json")
        try Data("{ nope".utf8).write(to: url)
        var threw = false
        do { _ = try SettingsStore(url: url).load() } catch { threw = true }
        expect(threw, true)
    }
}
