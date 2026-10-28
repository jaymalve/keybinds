import OSLog

/// `log stream --predicate 'subsystem == "com.jaymalve.keybinds"' --level debug`
enum Log {
    static let app = Logger(subsystem: "com.jaymalve.keybinds", category: "app")
    static let hotkey = Logger(subsystem: "com.jaymalve.keybinds", category: "hotkey")
    static let click = Logger(subsystem: "com.jaymalve.keybinds", category: "click")
}
