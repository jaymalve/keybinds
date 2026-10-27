import Foundation

// Minimal test harness: the Command Line Tools ship neither XCTest nor Swift Testing.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch {
        failures += 1
        print("  ✗ \(name): threw \(error)")
        return
    }
    if failures == before { passes += 1; print("  ✓ \(name)") } else { print("  ✗ \(name)") }
}

func expect<T: Equatable>(_ got: T, _ want: T, _ note: String = "", line: Int = #line) {
    guard got != want else { return }
    failures += 1
    print("    line \(line): got \(got), want \(want) \(note)")
}
