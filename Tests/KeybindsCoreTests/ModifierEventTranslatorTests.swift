import KeybindsCore

func modifierEventTranslatorTests() {
    print("ModifierEventTranslator")
    test("plain ⌥ press and release") {
        var t = ModifierEventTranslator()
        expect(t.flagsChanged([.option], at: 1), [.optionDown(1)])
        expect(t.flagsChanged([], at: 2), [.optionUp(2)])
    }
    test("⌥ while ⌘ is held is not a tap") {
        var t = ModifierEventTranslator()
        expect(t.flagsChanged([.command], at: 1), [.otherModifierDown(1)])
        expect(t.flagsChanged([.command, .option], at: 2), [.otherModifierDown(2)])
        expect(t.flagsChanged([.command], at: 3), [.otherModifierDown(3)])
    }
    test("releasing ⌘ while ⌥ stays held emits nothing") {
        var t = ModifierEventTranslator()
        _ = t.flagsChanged([.command, .option], at: 1)
        expect(t.flagsChanged([.option], at: 2), [])
        expect(t.flagsChanged([], at: 3), [.optionUp(3)])
    }
    test("⌘⌥ end to end doesn't trigger the detector") {
        var t = ModifierEventTranslator()
        var d = OptionTapDetector()
        let snapshots: [(ModifierFlags, Double)] = [
            ([.command], 0), ([.command, .option], 0.05), ([.command], 0.1), ([], 0.15),
        ]
        let fired = snapshots.flatMap { t.flagsChanged($0.0, at: $0.1) }.filter { d.handle($0) }.count
        expect(fired, 0)
    }
}
