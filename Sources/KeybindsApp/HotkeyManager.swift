import AppKit
import KeybindsCore

/// Owns both palette triggers: double-tap Shift (event monitors) and an optional key combo (Carbon).
/// `apply(_:)` takes effect immediately, so Settings changes need no restart.
@MainActor
final class HotkeyManager {
    private var settings: Settings
    private let onTrigger: () -> Void
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

    init(settings: Settings, onTrigger: @escaping () -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
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
