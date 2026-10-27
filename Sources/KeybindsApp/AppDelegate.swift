import AppKit
import KeybindsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = Settings.default
    private let palette = PaletteController()
    private var hotkeys: HotkeyManager!
    private var menuBar: MenuBarController!
    private var onboarding: OnboardingWindowController?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            settings = try SettingsStore().load()
        } catch {
            Log.app.error("settings.json unreadable, using defaults: \(error.localizedDescription)")
        }

        hotkeys = HotkeyManager(settings: settings) { [weak self] in self?.palette.toggle() }
        menuBar = MenuBarController(
            openPalette: { [weak self] in self?.palette.show() },
            showPermissions: { [weak self] in self?.showOnboarding() }
        )

        // Combos are Carbon hotkeys and work without any permission.
        hotkeys.startCombo()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.notice("launched v\(version, privacy: .public), accessibility granted: \(Permissions.accessibilityGranted)")

        if Permissions.accessibilityGranted {
            hotkeys.startDoubleShift()
        } else {
            showOnboarding()
            waitForAccessibility()
        }
    }

    private func showOnboarding() {
        if onboarding == nil { onboarding = OnboardingWindowController() }
        onboarding?.show()
    }

    /// Global key monitors only receive events once Accessibility is granted, so start them then.
    private func waitForAccessibility() {
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard Permissions.accessibilityGranted else { return }
                self?.permissionPoll?.invalidate()
                self?.permissionPoll = nil
                Log.app.notice("Accessibility granted")
                self?.hotkeys.startDoubleShift()
            }
        }
    }
}
