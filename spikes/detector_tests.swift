// Synthetic-sequence tests for DoubleTapDetector.
import Foundation

func fires(_ events: [KeyEvent]) -> Int {
    var d = DoubleTapDetector()
    return events.reduce(0) { $0 + (d.handle($1) ? 1 : 0) }
}
var failures = 0
func check(_ name: String, _ got: Int, _ want: Int) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name)  (fired \(got), want \(want))")
}

check("clean double tap",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28)]), 1)
check("typing 'Hello World' (shift held over letters)",
      fires([.shiftDown(0), .keyDown(0.05), .shiftUp(0.10), .keyDown(0.15), .keyDown(0.25),
             .shiftDown(0.40), .keyDown(0.45), .shiftUp(0.50)]), 0)
check("typing \"I'M\" fast",
      fires([.shiftDown(0), .keyDown(0.03), .keyDown(0.09), .keyDown(0.15), .shiftUp(0.18)]), 0)
check("gap too long",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.50), .shiftUp(0.58)]), 0)
check("gap too long, then third tap completes a new pair",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.50), .shiftUp(0.58), .shiftDown(0.70), .shiftUp(0.78)]), 1)
check("first hold too long (shift used as a held modifier)",
      fires([.shiftDown(0), .shiftUp(0.40), .shiftDown(0.50), .shiftUp(0.58)]), 0)
check("second hold too long",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.60)]), 0)
check("key pressed between taps",
      fires([.shiftDown(0), .shiftUp(0.08), .keyDown(0.12), .shiftDown(0.20), .shiftUp(0.28)]), 0)
check("⌘ involved (⌘⇧ shortcut)",
      fires([.shiftDown(0), .otherModifierDown(0.02), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28)]), 0)
check("triple tap fires once",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28), .shiftDown(0.40), .shiftUp(0.48)]), 1)
check("four taps fire twice",
      fires([.shiftDown(0), .shiftUp(0.08), .shiftDown(0.20), .shiftUp(0.28),
             .shiftDown(0.40), .shiftUp(0.48), .shiftDown(0.60), .shiftUp(0.68)]), 2)
print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
