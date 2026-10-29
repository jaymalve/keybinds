import AppKit
import KeybindsCore
import KeybindsPlatform

/// Click mode, search first: faint outlines show what's clickable; typing part of an element's name narrows to the
/// matches, ringing the best one and numbering the rest. ↩ (or letting go of ⌥) clicks the ringed one, a digit
/// clicks that match, Tab moves the ring. Space with nothing typed puts a letter label on everything instead.
/// ⌘ on the final key ⌘-clicks, ⇧ right-clicks.
///
/// Keys are read with an event tap rather than by making the overlay key, so the app underneath keeps focus and
/// its menus and popovers stay open.
@MainActor
final class ClickMode {
    private struct Item {
        let target: Clickable
        let text: PreparedText
    }

    private var overlays: [HintOverlay] = []
    private var items: [Item] = []
    private var window: CGRect = .zero
    private var query = ""
    /// Space with nothing typed: a letter label on every element, typed like Homerow's labels.
    private var showAll = false
    private var allLabels: [String] = []
    private var typedLabel = ""
    /// Indexes into `items`, best first.
    private var matches: [Int] = []
    private var focus = 0

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var scanTask: Task<Void, Never>?
    /// Key-ups of keys we swallowed, so the app doesn't see a stray release.
    private var swallowedKeys = Set<Int64>()
    /// The modifier being held to keep labels up; it doesn't count toward the click type.
    private var heldFlags: CGEventFlags = []

    /// Matches past this many get no number; keep typing to narrow them.
    static let numbered = 9
    private static let digitKeys: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

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
            let scan = await Task.detached { ElementScanner.scan(pid: pid) }.value
            guard let self, !Task.isCancelled else { return }
            scanTask = nil
            guard !scan.items.isEmpty else {
                NSSound.beep()
                Log.click.notice("nothing clickable in \(app.localizedName ?? "?", privacy: .public)")
                return
            }
            show(scan.window, scan.items)
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        removeTap()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        items = []
        matches = []
        query = ""
        typedLabel = ""
        showAll = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// The hold key was let go: click the ringed match, like letting go of ⌘ in ⌘Tab. Nothing typed: just close.
    func release() {
        guard isActive, !showAll, !query.isEmpty, matches.indices.contains(focus) else { stop(); return }
        click(matches[focus], flags: Self.flags(NSEvent.modifierFlags))
    }

    private func show(_ window: CGRect, _ found: [Clickable]) {
        self.window = window
        items = found.map { Item(target: $0, text: PreparedText($0.title)) }
        allLabels = HintLabels.make(items.count)
        guard installTap() else {
            Log.click.error("could not create the key event tap")
            NSSound.beep()
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            // AX frames have a top-left origin on the main screen; Cocoa's is bottom-left.
            let frames = items.map { item in
                let f = item.target.frame
                return CGRect(x: f.minX - screen.frame.minX, y: primaryHeight - f.maxY - screen.frame.minY,
                              width: f.width, height: f.height)
            }
            guard frames.contains(where: { CGRect(origin: .zero, size: screen.frame.size).contains(CGPoint(x: $0.midX, y: $0.midY)) })
            else { continue }
            let overlay = HintOverlay(screen: screen)
            overlay.view.frames = frames
            let w = CGRect(x: window.minX - screen.frame.minX, y: primaryHeight - window.maxY - screen.frame.minY,
                           width: window.width, height: window.height)
            overlay.view.pillAnchor = CGRect(origin: .zero, size: screen.frame.size).contains(CGPoint(x: w.midX, y: w.midY))
                ? CGPoint(x: w.midX, y: w.minY + 28) : nil
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                overlay.animator().alphaValue = 1
            }
            overlays.append(overlay)
        }
        render()
        // Switching apps (⌘Tab, a click elsewhere) ends click mode.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    // MARK: Search

    private func search() {
        focus = 0
        let tokens = query.lowercased().split(separator: " ").map(Array.init)
        guard !tokens.isEmpty else { matches = []; render(); return }
        var scored: [(index: Int, score: Int)] = []
        for (i, item) in items.enumerated() {
            var total = 0
            for token in tokens {
                guard let m = FuzzyMatcher.match(token, in: item.text) else { total = -1; break }
                total += m.score
            }
            if total >= 0 { scored.append((i, total)) }
        }
        // Ties keep reading order (top to bottom, left to right).
        matches = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.index)
        render()
    }

    private func render() {
        var marks = [HintOverlayView.Mark](repeating: .init(state: .hidden), count: items.count)
        let pill: HintOverlayView.Pill
        if showAll {
            for (i, label) in allLabels.enumerated() where label.hasPrefix(typedLabel) {
                marks[i] = .init(state: .match, label: label.uppercased(), typed: typedLabel.count)
            }
            pill = .init(text: typedLabel.uppercased(), placeholder: "Type a label", detail: "⌫ back to search")
        } else if query.isEmpty {
            marks = marks.map { _ in .init(state: .faint) }
            pill = .init(text: "", placeholder: "Type to search what to click", detail: "space  all labels")
        } else {
            for (rank, i) in matches.enumerated() {
                marks[i] = .init(state: rank == focus ? .focused : .match, label: rank < Self.numbered ? "\(rank + 1)" : nil)
            }
            let detail = matches.isEmpty ? "no matches" : matches.count == 1 ? "1 match" : "\(matches.count) matches"
            pill = .init(text: query, placeholder: "", detail: detail)
        }
        for overlay in overlays {
            overlay.view.marks = marks
            overlay.view.pill = pill
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
        case 36, 76:  // ↩
            if !showAll, matches.indices.contains(focus) { click(matches[focus], flags: flags) } else { NSSound.beep() }
        case 48, 125, 126:  // Tab / ↓ move the ring forward, ⇧Tab / ↑ back
            guard !showAll, !matches.isEmpty else { NSSound.beep(); break }
            let back = keyCode == 126 || (keyCode == 48 && flags.contains(.maskShift))
            focus = (focus + (back ? matches.count - 1 : 1)) % matches.count
            render()
        case 51:  // ⌫
            if showAll {
                if typedLabel.isEmpty { showAll = false } else { typedLabel.removeLast() }
                render()
            } else if !query.isEmpty {
                query.removeLast()
                search()
            }
        case 49 where query.isEmpty && !showAll:  // Space with nothing typed: label everything
            showAll = true
            render()
        default:
            if !showAll, let digit = Self.digitKeys[keyCode] {
                if digit < matches.count { click(matches[digit], flags: flags) } else { NSSound.beep() }
            } else if showAll {
                typeLabel(character.lowercased(), flags: flags)
            } else if let c = character.first, character.count == 1, !c.isNewline, c.isLetter || c.isPunctuation || c == " " {
                query.append(c)
                search()
            } else {
                NSSound.beep()
            }
        }
        return true
    }

    private func typeLabel(_ letter: String, flags: CGEventFlags) {
        let candidate = typedLabel + letter
        guard letter.count == 1, let hit = allLabels.firstIndex(where: { $0.hasPrefix(candidate) }) else {
            NSSound.beep()
            return
        }
        typedLabel = candidate
        if allLabels[hit] == candidate { click(hit, flags: flags) } else { render() }
    }

    private func click(_ index: Int, flags: CGEventFlags) {
        let flags = flags.subtracting(heldFlags)
        let action: ClickAction = flags.contains(.maskCommand) ? .commandClick
            : flags.contains(.maskShift) ? .rightClick : .click
        let target = items[index].target
        stop()
        Log.click.notice("\(String(describing: action), privacy: .public) \(target.role, privacy: .public) “\(target.title, privacy: .public)”")
        Clicker.perform(action, on: target)
    }

    private static func flags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let mode = Unmanaged<ClickMode>.fromOpaque(refcon).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // The plain character: with ⌥ held, the event's own string is "å" rather than "a".
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

/// Draws click mode: a light scrim with the elements in play cut out, outlines (faint, matched, ringed), glass number
/// or letter chips, and the search pill.
final class HintOverlayView: NSView {
    enum State { case hidden, faint, match, focused }

    struct Mark {
        var state: State
        var label: String? = nil
        var typed = 0
    }

    struct Pill {
        let text: String
        let placeholder: String
        let detail: String
    }

    /// Element frames in this view's coordinates, index-aligned with `marks`.
    var frames: [CGRect] = []
    var marks: [Mark] = [] { didSet { updateChips(); needsDisplay = true } }
    var pill: Pill? { didSet { updatePill() } }
    /// Bottom center of the front window, if it's on this screen.
    var pillAnchor: CGPoint?

    private var chips: [Int: HintChip] = [:]
    private var pillChip: HintChip?

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let visible = zip(frames, marks).filter { $0.1.state != .hidden }
        let narrowing = marks.contains { $0.state == .focused || $0.state == .match }
        // Once you're narrowing, a scrim with the matches left clear; before that, only faint outlines.
        if narrowing {
            NSColor.black.withAlphaComponent(0.28).setFill()
            bounds.fill()
            context.compositingOperation = .clear
            for (frame, _) in visible { Self.outline(frame).fill() }
            context.compositingOperation = .sourceOver
        }

        for (frame, mark) in visible {
            let path = Self.outline(frame)
            switch mark.state {
            case .hidden:
                continue
            case .faint:
                // Dark under light, so the outline shows on white pages and dark ones alike.
                Self.stroke(path, NSColor.black.withAlphaComponent(0.18), 2)
                Self.stroke(path, NSColor.white.withAlphaComponent(0.45), 1)
            case .match:
                Self.stroke(path, NSColor.black.withAlphaComponent(0.25), 2.5)
                Self.stroke(path, NSColor.white.withAlphaComponent(0.85), 1.25)
            case .focused:
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.8)
                glow.shadowBlurRadius = 8
                glow.set()
                Self.stroke(path, NSColor.controlAccentColor, 2.5)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private static func outline(_ frame: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
    }

    private static func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    /// One chip per labelled element, reused while the label stays the same.
    private func updateChips() {
        var keep: [Int: HintChip] = [:]
        for (i, mark) in marks.enumerated() {
            guard let label = mark.label, frames.indices.contains(i) else { continue }
            let chip = chips[i].flatMap { $0.text == label ? $0 : nil } ?? HintChip(text: label)
            chip.typedCount = mark.typed
            if chip.superview == nil {
                let size = chip.fittingSize
                let f = frames[i]
                // Just left of the element so its text stays readable; small elements (icons) get it centered.
                let x = f.width < size.width * 2.5 ? f.midX - size.width / 2 : max(2, f.minX - size.width + 6)
                chip.frame = CGRect(x: x, y: f.midY - size.height / 2, width: size.width, height: size.height).integral
                addSubview(chip)
            }
            keep[i] = chip
        }
        for (i, chip) in chips where keep[i] !== chip { chip.removeFromSuperview() }
        chips = keep
    }

    private func updatePill() {
        guard let pill, let anchor = pillAnchor else { pillChip?.removeFromSuperview(); pillChip = nil; return }
        let chip = pillChip ?? HintChip(text: "", height: 34, fontSize: 14)
        let icon = NSTextAttachment()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white.withAlphaComponent(0.5)])))
        let string = NSMutableAttributedString(attachment: icon)
        string.append(NSAttributedString(string: "  "))
        string.append(NSAttributedString(string: pill.text.isEmpty ? pill.placeholder : pill.text, attributes: [
            .font: chip.font, .foregroundColor: NSColor.white.withAlphaComponent(pill.text.isEmpty ? 0.5 : 1),
        ]))
        string.append(NSAttributedString(string: "    \(pill.detail)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.45),
        ]))
        chip.attributed = string
        if pillChip == nil { addSubview(chip); pillChip = chip }
        let size = chip.fittingSize
        let width = max(size.width, 300)
        chip.frame = CGRect(x: anchor.x - width / 2, y: anchor.y, width: width, height: size.height).integral
    }
}

/// One label: Liquid Glass on macOS 26, a dark frosted blur before that.
final class HintChip: NSView {
    let text: String
    let font: NSFont
    private let field = NSTextField(labelWithString: "")
    private let height: CGFloat

    var typedCount = 0 { didSet { if typedCount != oldValue { updateText() } } }
    /// Replaces the text styling entirely (the search pill).
    var attributed: NSAttributedString? { didSet { if let attributed { field.attributedStringValue = attributed } } }

    init(text: String, height: CGFloat = 20, fontSize: CGFloat = 11.5) {
        self.text = text
        self.height = height
        let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize) ?? base
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = height / 2
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = height / 2
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
        backing.layer?.cornerRadius = height / 2
        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: height * 0.35),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -height * 0.35),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: height),
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
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .kern: 0.6,
        ])
        string.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.35),
                            range: NSRange(location: 0, length: min(typedCount, text.count)))
        field.attributedStringValue = string
        field.alignment = .center
    }
}
