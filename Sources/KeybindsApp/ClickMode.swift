import AppKit
import KeybindsCore
import KeybindsPlatform

/// Click mode: a label on everything clickable in the front window; typing a label clicks it.
///
/// Keys are read with an event tap rather than by making the overlay key, so the app underneath keeps focus and
/// its menus and popovers stay open. ⌘ while finishing a label ⌘-clicks, ⇧ right-clicks.
/// Started by holding ⌥ (labels go when it's let go), or by Tab in the palette / a shortcut (labels stay until Esc).
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
    /// The modifier being held to keep labels up; it doesn't count toward the click type.
    private var heldFlags: CGEventFlags = []

    var isActive: Bool { tap != nil }

    func toggle() {
        isActive ? stop() : start()
    }

    func start(holding: CGEventFlags = []) {
        guard !isActive, scanTask == nil else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            NSSound.beep()
            return
        }
        heldFlags = holding
        let pid = app.processIdentifier
        scanTask = Task { [weak self] in
            let found = await Task.detached { ElementScanner.scan(pid: pid) }.value
            guard let self, !Task.isCancelled else { return }
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
        scanTask?.cancel()
        scanTask = nil
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
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                overlay.animator().alphaValue = 1
            }
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
            let flags = flags.subtracting(heldFlags)
            let action: ClickAction = flags.contains(.maskCommand) ? .commandClick
                : flags.contains(.maskShift) ? .rightClick : .click
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
            // The plain letter: with ⌥ held, the event's own string is "å" rather than "a".
            let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
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

/// Draws the labels as small glass capsules, and once you start typing, a soft outline around the elements
/// still in play.
final class HintOverlayView: NSView {
    struct Hint {
        let label: String
        /// In this view's coordinates.
        let frame: CGRect
    }

    var hints: [Hint] = [] { didSet { rebuild() } }
    var typed = "" { didSet { refresh() } }

    private var chips: [HintChip] = []

    override func draw(_ dirtyRect: NSRect) {
        guard !typed.isEmpty else { return }
        for hint in hints where hint.label.hasPrefix(typed) {
            let path = NSBezierPath(roundedRect: hint.frame.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        chips = hints.map { hint in
            let chip = HintChip(label: hint.label)
            let size = chip.fittingSize
            // Just left of the element so its text stays readable, overlapping it a little; small elements
            // (icons) get the label centered on them.
            let x = hint.frame.width < size.width * 2.5 ? hint.frame.midX - size.width / 2
                : max(2, hint.frame.minX - size.width + 6)
            chip.frame = CGRect(x: x, y: hint.frame.midY - size.height / 2, width: size.width, height: size.height).integral
            addSubview(chip)
            return chip
        }
        refresh()
    }

    private func refresh() {
        for (chip, hint) in zip(chips, hints) {
            chip.isHidden = !hint.label.hasPrefix(typed)
            if !chip.isHidden { chip.typedCount = typed.count }
        }
        needsDisplay = true
    }
}

/// One label: Liquid Glass on macOS 26, a dark frosted blur before that.
final class HintChip: NSView {
    private let label: String
    private let text = NSTextField(labelWithString: "")
    private static let height: CGFloat = 20

    var typedCount = 0 { didSet { if typedCount != oldValue { updateText() } } }

    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 11.5) ?? base
    }()

    init(label: String) {
        self.label = label.uppercased()
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.height / 2
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.height / 2
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 0.5
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            background = blur
        }
        // Glass adapts to what's behind it and turns pale over white pages; a dark capsule underneath keeps every
        // label equally legible.
        let backing = NSView()
        backing.wantsLayer = true
        backing.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        backing.layer?.cornerRadius = Self.height / 2
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
        ])
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        updateText()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateText() {
        let string = NSMutableAttributedString(string: label, attributes: [
            .font: Self.font, .foregroundColor: NSColor.white, .kern: 0.6,
        ])
        string.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.35),
                            range: NSRange(location: 0, length: min(typedCount, label.count)))
        text.attributedStringValue = string
        text.alignment = .center
    }
}
