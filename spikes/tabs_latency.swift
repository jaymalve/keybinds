// Spike M0.1: batched tab enumeration latency via NSAppleScript (in-process, compiled once).
import Foundation
import AppKit

func running(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

let scripts: [(String, String, String)] = [
    ("Chrome", "com.google.Chrome",
     #"tell application id "com.google.Chrome" to return {id of tabs of windows, title of tabs of windows, URL of tabs of windows, id of windows}"#),
    ("Brave", "com.brave.Browser",
     #"tell application id "com.brave.Browser" to return {id of tabs of windows, title of tabs of windows, URL of tabs of windows, id of windows}"#),
    ("Safari", "com.apple.Safari",
     #"tell application id "com.apple.Safari" to return {name of tabs of windows, URL of tabs of windows, id of windows}"#),
    ("Terminal", "com.apple.Terminal",
     #"tell application id "com.apple.Terminal" to return {tty of tabs of windows, custom title of tabs of windows, id of windows}"#),
]

for (name, bid, src) in scripts {
    guard running(bid) else { print("\(name): not running, skipped (no launch)"); continue }
    let script = NSAppleScript(source: src)!
    var err: NSDictionary?
    script.compileAndReturnError(&err)
    var times: [Double] = []
    var tabCount = 0, winCount = 0
    for _ in 0..<5 {
        let t0 = DispatchTime.now()
        let res = script.executeAndReturnError(&err)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        if let err { print("\(name): error \(err)"); break }
        let wins = res.atIndex(1)!
        winCount = wins.numberOfItems
        tabCount = (1...max(winCount, 1)).reduce(0) { $0 + (winCount == 0 ? 0 : wins.atIndex($1)!.numberOfItems) }
    }
    if err == nil {
        let sorted = times.sorted()
        print(String(format: "%@: %d windows, %d tabs | first %.1f ms, median %.1f ms, max %.1f ms",
                     name, winCount, tabCount, times[0], sorted[2], sorted[4]))
    }
}
