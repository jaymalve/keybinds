import AppKit
import KeybindsCore
import KeybindsPlatform

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsModel = SettingsModel()
    private let index = TargetIndex()
    private let favicons = FaviconStore()
    private lazy var palette = PaletteController(index: index, favicons: favicons)
    private let clickMode = ClickMode()
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)
    private var hotkeys: HotkeyManager!
    private var menuBar: MenuBarController!
    private var onboarding: OnboardingWindowController?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = settingsModel.settings
        hotkeys = HotkeyManager(settings: settings,
                                onTrigger: { [weak self] in
                                    // The shortcut and Tab keep click mode up; ⌥ tapped during it isn't a palette request.
                                    guard self?.clickMode.isActive != true else { return }
                                    self?.palette.toggle()
                                },
                                onClickMode: { [weak self] in self?.startClickMode() },
                                onHold: { [weak self] down in self?.clickModeHeld(down) })
        hotkeys.apply(settings)
        index.apply(settings)
        palette.apply(settings)

        settingsModel.onChange = { [weak self] settings in
            guard let self else { return }
            hotkeys.apply(settings)
            index.apply(settings)
            palette.apply(settings)
            settingsModel.comboError = hotkeys.comboError
            settingsModel.clickComboError = hotkeys.clickComboError
        }
        settingsModel.onRecordingChange = { [weak self] recording in self?.hotkeys.setPaused(recording) }
        settingsModel.comboError = hotkeys.comboError
        settingsModel.clickComboError = hotkeys.clickComboError

        menuBar = MenuBarController(
            openPalette: { [weak self] in self?.palette.show() },
            showSettings: { [weak self] in self?.settingsWindow.show() },
            showPermissions: { [weak self] in self?.showOnboarding() }
        )
        palette.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        palette.onClickMode = { [weak self] in self?.startClickMode() }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.notice("launched v\(version, privacy: .public), accessibility granted: \(Permissions.accessibilityGranted)")

        if Permissions.accessibilityGranted {
            hotkeys.accessibilityGranted()
        } else {
            showOnboarding()
            waitForAccessibility()
        }
    }

    /// Holding the hold key shows labels; letting go hides them (after a click they're already gone).
    private func clickModeHeld(_ down: Bool) {
        guard down else { clickMode.release(); return }
        palette.hide()
        clickMode.start(holding: settingsModel.settings.clickHoldKey == .rightCommand ? .maskCommand : .maskAlternate)
    }

    private func startClickMode() {
        palette.hide()
        clickMode.toggle()
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
                self?.hotkeys.accessibilityGranted()
                self?.index.refresh()
            }
        }
    }
}
