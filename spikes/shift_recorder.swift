// Spike M0.6: record real keyboard *timing* (never characters or key codes), then replay it through DoubleTapDetector.
// Usage: shift_recorder <seconds>   — type normally during the recording, plus a few deliberate double-Shift taps.
// Needs Input Monitoring for the app you run it from (e.g. Terminal).
import Foundation
import CoreGraphics

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "180") ?? 180
var events: [KeyEvent] = []
var shiftHeld = false
var otherMods: CGEventFlags = []
let otherMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn, .maskAlphaShift]
var holds: [Double] = [], gaps: [Double] = []
var lastShiftDown = 0.0, lastShiftUp = -1.0
var live = DoubleTapDetector()
var firstT: Double? = nil
var keyCount = 0

let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
let callback: CGEventTapCallBack = { _, type, event, _ in
    let t = Double(event.timestamp) / 1e9
    if firstT == nil { firstT = t }
    let before = events.count
    defer {
        for e in events[before...] where live.handle(e) {
            print(String(format: "  ⇧⇧ double-Shift detected at %.1fs", t - firstT!)); fflush(stdout)
        }
    }
    if type == .keyDown {
        events.append(.keyDown(t)); keyCount += 1
    } else if type == .flagsChanged {
        let flags = event.flags
        let shift = flags.contains(.maskShift)
        let others = flags.intersection(otherMask)
        if !others.isEmpty && others != otherMods { events.append(.otherModifierDown(t)) }
        otherMods = others
        if shift && !shiftHeld {
            events.append(.shiftDown(t)); lastShiftDown = t
            if lastShiftUp > 0 { gaps.append(t - lastShiftUp) }
        } else if !shift && shiftHeld {
            events.append(.shiftUp(t)); holds.append(t - lastShiftDown); lastShiftUp = t
        }
        shiftHeld = shift
    }
    return Unmanaged.passUnretained(event)
}

guard CGPreflightListenEventAccess() else {
    CGRequestListenEventAccess()
    print("No Input Monitoring permission. Grant it to the app running this (System Settings → Privacy & Security → Input Monitoring), restart that app, then retry.")
    exit(1)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) else {
    print("Could not create event tap. Grant Input Monitoring to the app running this (System Settings → Privacy & Security → Input Monitoring), then retry.")
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("Recording for \(Int(seconds))s. Type normally (anywhere), and do a few deliberate double-Shift taps. Only timings are recorded.\nEach detected double-Shift prints immediately; the full analysis prints at the end. Ctrl-C to abort.")
fflush(stdout)
let started = Date()
let ticker = Timer(timeInterval: 30, repeats: true) { _ in
    print(String(format: "  … %.0fs elapsed, %d keys recorded", Date().timeIntervalSince(started), keyCount)); fflush(stdout)
}
RunLoop.current.add(ticker, forMode: .default)
CFRunLoopRunInMode(.defaultMode, seconds, false)

let keyDowns = events.filter { if case .keyDown = $0 { return true }; return false }.count
print("\nRecorded \(events.count) events (\(keyDowns) key presses).")

func pct(_ xs: [Double], _ p: Double) -> String {
    guard !xs.isEmpty else { return "-" }
    let s = xs.sorted(); return String(format: "%.0f ms", s[min(s.count - 1, Int(Double(s.count) * p))] * 1000)
}
print("Shift hold times  p50 \(pct(holds, 0.5))  p90 \(pct(holds, 0.9))  max \(pct(holds, 1))")
print("Shift-to-shift gaps  p10 \(pct(gaps, 0.1))  p50 \(pct(gaps, 0.5))")

for (hold, gap) in [(0.15, 0.25), (0.20, 0.30), (0.25, 0.40)] {
    var d = DoubleTapDetector(); d.maxHold = hold; d.maxGap = gap
    var fireTimes: [Double] = []
    for e in events { if d.handle(e), case .shiftUp(let t) = e { fireTimes.append(t) } }
    let start = events.first.map { e -> Double in switch e { case .shiftDown(let t), .shiftUp(let t), .keyDown(let t), .otherModifierDown(let t): return t } } ?? 0
    print(String(format: "hold ≤ %.0f ms, gap ≤ %.0f ms → fired %d time(s) at: %@", hold * 1000, gap * 1000, fireTimes.count,
                 fireTimes.map { String(format: "%.1fs", $0 - start) }.joined(separator: ", ")))
}
print("\nCompare the fire times with when you deliberately double-tapped. Any extra fire = a false trigger.")
