import AppKit
import KeybindsCore
import KeybindsPlatform

/// Click mode: a label on everything clickable in the front window; typing a label clicks it.
///
/// Keys are read with an event tap rather than by making the overlay key, so the app underneath keeps focus and
/// its menus and popovers stay open. ⌘ while finishing a label ⌘-clicks, ⇧ right-clicks, ⌥ only moves the pointer.
@MainActor
final class ClickMode {
    private var overlays: [HintOverlay] = []
    private var hints: [(label: String, target: Clickable)] = []
    private var typed = ""
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var scanTask: Task<Void, Never>?
    /// Key-ups of keys we swallowed, so the app doesn't see a stray release.
    private var swallowedKeys = Set<Int64>()

    var isActive: Bool { tap != nil }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive, scanTask == nil, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { NSSound.beep(); return }
        let pid = app.processIdentifier
        scanTask = Task { [weak self] in
            let found = await Task.detached { ElementScanner.scan(pid: pid) }.value
            guard let self else { return }
            scanTask = nil
            guard !found.isEmpty else {
                NSSound.beep()
                Log.click.notice("nothing clickable in \(app.localizedName ?? "?", privacy: .public)")
                return
            }
            show(found)
        }
    }

    func stop() {
        removeTap()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        hints = []
        typed = ""
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func show(_ found: [Clickable]) {
        let labels = HintLabels.make(found.count)
        hints = Array(zip(labels, found))
        typed = ""
        guard installTap() else {
            Log.click.error("could not create the key event tap")
            NSSound.beep()
            return
        }
        // Labels for the elements on each screen, in that screen's own coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let overlay = HintOverlay(screen: screen)
            overlay.view.hints = hints.compactMap { hint in
                let f = hint.target.frame
                // AX frames have a top-left origin on the main screen; Cocoa's is bottom-left.
                let cocoa = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                guard screen.frame.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) else { return nil }
                return HintOverlayView.Hint(label: hint.label, frame: cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            }
            guard !overlay.view.hints.isEmpty else { continue }
            overlay.orderFrontRegardless()
            overlays.append(overlay)
        }
        // Switching apps (⌘Tab, a click elsewhere) ends click mode.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    // MARK: Keys

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags, character: String) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            stop()
            return false
        case .keyUp:
            return swallowedKeys.remove(keyCode) != nil
        case .keyDown:
            break
        default:
            return false
        }
        swallowedKeys.insert(keyCode)
        switch keyCode {
        case 53:  // Esc
            stop()
            return true
        case 51:  // ⌫
            if !typed.isEmpty { typed.removeLast() }
            update()
            return true
        default:
            break
        }
        let letter = character.lowercased()
        guard letter.count == 1, let c = letter.first, HintLabels.alphabet.contains(c) else {
            NSSound.beep()
            return true
        }
        let candidate = typed + letter
        let matching = hints.filter { $0.label.hasPrefix(candidate) }
        guard !matching.isEmpty else {
            NSSound.beep()
            return true
        }
        typed = candidate
        if let hit = matching.first(where: { $0.label == candidate }) {
            let action: ClickAction = flags.contains(.maskCommand) ? .commandClick
                : flags.contains(.maskShift) ? .rightClick
                : flags.contains(.maskAlternate) ? .hover : .click
            let target = hit.target
            stop()
            Log.click.notice("\(String(describing: action), privacy: .public) \(target.role, privacy: .public) “\(target.title, privacy: .public)”")
            Clicker.perform(action, on: target)
        } else {
            update()
        }
        return true
    }

    private func update() {
        for overlay in overlays { overlay.view.typed = typed }
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let mode = Unmanaged<ClickMode>.fromOpaque(refcon).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            let character = String(utf16CodeUnits: chars, count: length)
            // The tap's run loop source is on the main run loop.
            let swallow = MainActor.assumeIsolated {
                mode.handle(type, keyCode: keyCode, flags: flags, character: character)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        // Releases of keys swallowed so far still need swallowing, but the tap is gone; they're harmless.
        swallowedKeys = []
    }
}

/// A transparent, click-through window over one screen that draws the labels.
final class HintOverlay: NSPanel {
    let view = HintOverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HintOverlayView: NSView {
    struct Hint {
        let label: String
        /// In this view's coordinates.
        let frame: CGRect
    }

    var hints: [Hint] = [] { didSet { needsDisplay = true } }
    var typed = "" { didSet { needsDisplay = true } }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let text = NSColor(white: 0.08, alpha: 1)
    private static let typedText = NSColor(white: 0.08, alpha: 0.35)
    private static let fill = NSColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 0.96)
    private static let border = NSColor(white: 0, alpha: 0.35)

    override func draw(_ dirtyRect: NSRect) {
        for hint in hints where hint.label.hasPrefix(typed) {
            let label = hint.label.uppercased()
            let string = NSMutableAttributedString(string: label, attributes: [.font: Self.font, .foregroundColor: Self.text])
            string.addAttribute(.foregroundColor, value: Self.typedText, range: NSRange(location: 0, length: typed.count))
            let size = string.size()
            let pill = CGSize(width: size.width + 8, height: size.height + 2)
            // Inside the element at its left edge, vertically centered; small elements get the label centered.
            let x = hint.frame.width < pill.width * 2.5 ? hint.frame.midX - pill.width / 2 : hint.frame.minX + 2
            let rect = CGRect(x: x, y: hint.frame.midY - pill.height / 2, width: pill.width, height: pill.height).integral
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            Self.fill.setFill()
            path.fill()
            Self.border.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            string.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 1))
        }
    }
}
