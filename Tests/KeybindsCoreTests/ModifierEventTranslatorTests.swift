import KeybindsCore

func modifierEventTranslatorTests() {
    print("ModifierEventTranslator")
    test("plain Shift press and release") {
        var t = ModifierEventTranslator()
        expect(t.flagsChanged([.shift], at: 1), [.shiftDown(1)])
        expect(t.flagsChanged([], at: 2), [.shiftUp(2)])
    }
    test("Shift while ⌘ is held is not a tap") {
        var t = ModifierEventTranslator()
        expect(t.flagsChanged([.command], at: 1), [.otherModifierDown(1)])
        expect(t.flagsChanged([.command, .shift], at: 2), [.otherModifierDown(2)])
        expect(t.flagsChanged([.command], at: 3), [.otherModifierDown(3)])
    }
    test("releasing ⌘ while Shift stays held emits nothing") {
        var t = ModifierEventTranslator()
        _ = t.flagsChanged([.command, .shift], at: 1)
        expect(t.flagsChanged([.shift], at: 2), [])
        expect(t.flagsChanged([], at: 3), [.shiftUp(3)])
    }
    test("⌘⇧⇧ end to end doesn't trigger the detector") {
        var t = ModifierEventTranslator()
        var d = DoubleTapDetector()
        let snapshots: [(ModifierFlags, Double)] = [
            ([.command], 0), ([.command, .shift], 0.05), ([.command], 0.1),
            ([.command, .shift], 0.2), ([.command], 0.25), ([], 0.3),
        ]
        let fired = snapshots.flatMap { t.flagsChanged($0.0, at: $0.1) }.filter { d.handle($0) }.count
        expect(fired, 0)
    }
}
