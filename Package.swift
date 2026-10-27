// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keybinds",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Keybinds", targets: ["KeybindsApp"]),
    ],
    targets: [
        // Pure logic, no AppKit. Everything here is covered by KeybindsCoreTests.
        .target(name: "KeybindsCore"),
        // macOS integration: Accessibility, window discovery, activation, private SkyLight/AX APIs.
        .target(name: "KeybindsPlatform", dependencies: ["KeybindsCore"]),
        // The AppKit/SwiftUI shell. Bundled into Keybinds.app by scripts/bundle.sh.
        .executableTarget(name: "KeybindsApp", dependencies: ["KeybindsCore", "KeybindsPlatform"]),
        // The Command Line Tools ship neither XCTest nor Swift Testing, so tests are a small
        // executable: `swift run KeybindsCoreTests`. Switch to Swift Testing if Xcode gets installed.
        .executableTarget(name: "KeybindsCoreTests", dependencies: ["KeybindsCore"], path: "Tests/KeybindsCoreTests"),
    ]
)
