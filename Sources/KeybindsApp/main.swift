import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar agent: no Dock icon (LSUIElement also set in Info.plist)
app.run()
