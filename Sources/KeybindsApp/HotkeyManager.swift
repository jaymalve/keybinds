import AppKit
import KeybindsCore

/// Owns the palette triggers, double-tap Shift (event monitors) and an optional key combo (Carbon), plus the
/// optional click-mode combo.
/// `apply(_:)` takes effect immediately, so Settings changes need no restart.
@MainActor
final class HotkeyManager {
    private var settings: Settings
    private let onTrigger: () -> Void
    private let onClickMode: () -> Void
    private var translator = ModifierEventTranslator()
    private var detector: DoubleTapDetector
    private var monitors: [Any] = []
    private var accessibilityReady = false

    private var combo: CarbonHotKey?
    private var registeredCombo: KeyCombo?
    private var paused = false
    private var activationObserver: NSObjectProtocol?
    /// Set when the combo couldn't be registered (usually: another app owns it).
    private(set) var comboError: String?
    private var clickCombo: CarbonHotKey?
    private var registeredClickCombo: KeyCombo?
    private(set) var clickComboError: String?

    init(settings: Settings, onTrigger: @escaping () -> Void, onClickMode: @escaping () -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
        self.onClickMode = onClickMode
        self.detector = DoubleTapDetector(timing: settings.doubleTap)
        // Release the combo while an excluded app is frontmost, so that app receives it.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCombo() }
        }
    }

    func apply(_ settings: Settings) {
        self.settings = settings
        detector = DoubleTapDetector(timing: settings.doubleTap)
        if settings.doubleShiftEnabled { startDoubleShiftIfReady() } else { stopDoubleShift() }
        updateCombo()
    }

    /// Call once Accessibility is granted. Listen-only: events are observed, never consumed.
    func accessibilityGranted() {
        accessibilityReady = true
        startDoubleShiftIfReady()
    }

    /// While recording a new shortcut, the current one must not swallow the keystroke.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        updateCombo()
    }

    // MARK: Double Shift

    private func startDoubleShiftIfReady() {
        guard accessibilityReady, settings.doubleShiftEnabled, monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        // Global monitor: events going to other apps. Local monitor: events going to Keybinds (palette is key).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
        Log.hotkey.notice("double-Shift monitoring started")
    }

    private func stopDoubleShift() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        let events: [KeyEvent]
        switch event.type {
        case .keyDown:
            events = [.keyDown(event.timestamp)]
        case .flagsChanged:
            events = translator.flagsChanged(ModifierFlags(event.modifierFlags), at: event.timestamp)
        default:
            return
        }
        for e in events where detector.handle(e) {
            Log.hotkey.debug("double-Shift fired")
            onTrigger()
        }
    }

    // MARK: Combo

    private func updateCombo() {
        updatePaletteCombo()
        updateClickCombo()
    }

    private func updatePaletteCombo() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let excluded = frontmost.map(settings.comboExcludedBundleIDs.contains) ?? false
        let wanted = paused || excluded ? nil : settings.paletteCombo
        guard wanted != registeredCombo || (wanted != nil && combo == nil) else { return }

        combo?.unregister()
        combo = nil
        registeredCombo = wanted
        comboError = nil
        guard let wanted else { return }
        combo = CarbonHotKey(combo: wanted) { [weak self] in self?.onTrigger() }
        if combo == nil {
            comboError = "\(wanted.displayString) is already used by another app."
            Log.hotkey.error("could not register palette combo \(wanted.displayString, privacy: .public)")
        }
    }

    /// Click mode has no exclusion list: it's meant to work in every app.
    private func updateClickCombo() {
        let wanted = paused ? nil : settings.clickCombo
        guard wanted != registeredClickCombo || (wanted != nil && clickCombo == nil) else { return }
        clickCombo?.unregister()
        clickCombo = nil
        registeredClickCombo = wanted
        clickComboError = nil
        guard let wanted else { return }
        clickCombo = CarbonHotKey(combo: wanted) { [weak self] in self?.onClickMode() }
        if clickCombo == nil {
            clickComboError = "\(wanted.displayString) is already used by another app."
            Log.hotkey.error("could not register click combo \(wanted.displayString, privacy: .public)")
        }
    }
}

private extension ModifierFlags {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.function) { insert(.function) }
    }
}
