import KeybindsCore

private func fires(_ events: [KeyEvent], timing: DoubleTapTiming = .default) -> Int {
    var d = DoubleTapDetector(timing: timing)
    return events.reduce(0) { $0 + (d.handle($1) ? 1 : 0) }
}

func doubleTapDetectorTests() {
    print("DoubleTapDetector")
    test("clean double tap fires") {
        expect(fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28)]), 1)
    }
    test("typing 'Hello World' doesn't fire") {
        expect(fires([.shiftDown(0), .keyDown(0.05), .shiftUp(0.10), .keyDown(0.15), .keyDown(0.25),
                      .shiftDown(0.40), .keyDown(0.45), .shiftUp(0.50)]), 0)
    }
    test("typing \"I'M\" fast doesn't fire") {
        expect(fires([.shiftDown(0), .keyDown(0.03), .keyDown(0.09), .keyDown(0.15), .shiftUp(0.18)]), 0)
    }
    test("gap too long doesn't fire") {
        expect(fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.50), .shiftUp(0.58)]), 0)
    }
    test("late second tap can start a new pair") {
        expect(fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.50), .shiftUp(0.58),
                      .shiftDown(0.70), .shiftUp(0.78)]), 1)
    }
    test("first hold too long doesn't fire") {
        expect(fires([.shiftDown(0), .shiftUp(0.40), .shiftDown(0.50), .shiftUp(0.58)]), 0)
    }
    test("second hold too long doesn't fire") {
        expect(fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.60)]), 0)
    }
    test("key between taps doesn't fire") {
        expect(fires([.shiftDown(0), .shiftUp(0.08), .keyDown(0.12), .shiftDown(0.20), .shiftUp(0.28)]), 0)
    }
    test("⌘ involved doesn't fire") {
        expect(fires([.shiftDown(0), .otherModifierDown(0.02), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28)]), 0)
    }
    test("triple tap fires once, four taps fire twice") {
        let tap = { (t: Double) -> [KeyEvent] in [.shiftDown(t), .shiftUp(t + 0.08)] }
        expect(fires(tap(0) + tap(0.2) + tap(0.4)), 1)
        expect(fires(tap(0) + tap(0.2) + tap(0.4) + tap(0.6)), 2)
    }
    test("timing is configurable") {
        let slow: [KeyEvent] = [.shiftDown(0), .shiftUp(0.08), .shiftDown(0.45), .shiftUp(0.53)]
        expect(fires(slow), 0)
        expect(fires(slow, timing: DoubleTapTiming(maxHold: 0.2, maxGap: 0.5)), 1)
    }
}
