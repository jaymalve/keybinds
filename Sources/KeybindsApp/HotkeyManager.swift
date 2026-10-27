import AppKit
import KeybindsCore

/// Owns both palette triggers: double-tap Shift (event monitors) and an optional key combo (Carbon).
@MainActor
final class HotkeyManager {
    private let settings: Settings
    private let onTrigger: () -> Void
    private var translator = ModifierEventTranslator()
    private var detector: DoubleTapDetector
    private var monitors: [Any] = []
    private var combo: CarbonHotKey?

    init(settings: Settings, onTrigger: @escaping () -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
        self.detector = DoubleTapDetector(timing: settings.doubleTap)
    }

    /// Needs Accessibility. Listen-only: events are observed, never consumed.
    func startDoubleShift() {
        guard settings.doubleShiftEnabled, monitors.isEmpty else { return }
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

    func startCombo() {
        guard let keyCombo = settings.paletteCombo, combo == nil else { return }
        combo = CarbonHotKey(combo: keyCombo) { [weak self] in self?.onTrigger() }
        if combo == nil { Log.hotkey.error("could not register palette combo (already taken?)") }
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
