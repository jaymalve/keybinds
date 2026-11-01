import KeybindsCore

private func fires(_ events: [KeyEvent]) -> Int {
    var d = OptionTapDetector()
    return events.reduce(0) { $0 + (d.handle($1) ? 1 : 0) }
}

func optionTapDetectorTests() {
    print("OptionTapDetector")
    test("clean tap fires") {
        expect(fires([.optionDown(0), .optionUp(0.08)]), 1)
    }
    test("each tap fires once") {
        expect(fires([.optionDown(0), .optionUp(0.08), .optionDown(0.20), .optionUp(0.28)]), 2)
    }
    test("hold too long doesn't fire") {
        expect(fires([.optionDown(0), .optionUp(0.21)]), 0)
    }
    test("stays below the click mode hold delay") {
        expect(OptionTapDetector.maxHold < 0.25, true)
    }
    test("⌥-letter or ⌥-click doesn't fire") {
        expect(fires([.optionDown(0), .keyDown(0.03), .optionUp(0.08)]), 0)
    }
    test("⌘ involved doesn't fire") {
        expect(fires([.optionDown(0), .otherModifierDown(0.02), .optionUp(0.08)]), 0)
    }
    test("a release with no press doesn't fire") {
        expect(fires([.optionUp(0.08)]), 0)
    }
}
