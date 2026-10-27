import AppKit
import KeybindsCore
import KeybindsPlatform
import SwiftUI

@MainActor
@Observable
final class PaletteModel {
    static let maxResults = 60

    let index: TargetIndex
    var query = "" { didSet { selectedID = nil } }
    /// The selected target, by identity: rows reorder while scans land, and an index would drift onto a neighbor.
    /// nil means "the first result".
    var selectedID: String?
    /// Bumped on every show so the view can re-focus the search field.
    var showCount = 0

    init(index: TargetIndex) {
        self.index = index
    }

    var results: [RankedTarget] {
        Array(index.search.search(query).prefix(Self.maxResults))
    }

    func selectedIndex(in results: [RankedTarget]) -> Int {
        selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    var selectedTarget: Target? {
        let results = results
        return results.isEmpty ? nil : results[selectedIndex(in: results)].target
    }

    func moveSelection(by delta: Int) {
        let results = results
        guard !results.isEmpty else { return }
        let next = (selectedIndex(in: results) + delta + results.count) % results.count
        selectedID = results[next].id
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 680, height: 420)

    private let model: PaletteModel
    private let activator: Activator
    private lazy var panel: PalettePanel = makePanel()
    private var keyMonitor: Any?

    init(index: TargetIndex) {
        model = PaletteModel(index: index)
        activator = Activator(index: index)
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.index.refresh()
        model.query = ""
        model.selectedID = nil
        model.showCount += 1
        panel.setFrame(frameOnActiveScreen(), display: false)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    // MARK: - NSWindowDelegate

    /// Clicking anywhere else dismisses the palette.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Private

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size))
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: PaletteView(model: model) { [weak self] target in
            self?.open(target)
        })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return panel
    }

    /// Centered horizontally on the screen under the mouse, in its upper third.
    private func frameOnActiveScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: Self.size) }
        return NSRect(x: visible.midX - Self.size.width / 2,
                      y: visible.maxY - visible.height * 0.18 - Self.size.height,
                      width: Self.size.width, height: Self.size.height)
    }

    /// Hide first so the panel gives up key focus before the target takes it.
    private func open(_ target: Target) {
        hide()
        activator.activate(target)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let control = event.modifierFlags.contains(.control)
            let consumed = MainActor.assumeIsolated { self?.handleKey(keyCode, control: control) ?? false }
            return consumed ? nil : event
        }
    }

    /// Returns true when the key was handled and shouldn't reach the search field.
    private func handleKey(_ keyCode: UInt16, control: Bool) -> Bool {
        guard panel.isKeyWindow else { return false }
        switch (keyCode, control) {
        case (53, _):  // Esc
            hide()
        case (125, _), (45, true):  // ↓, ⌃N
            model.moveSelection(by: 1)
        case (126, _), (35, true):  // ↑, ⌃P
            model.moveSelection(by: -1)
        case (36, _), (76, _):  // Return, keypad Enter
            guard let target = model.selectedTarget else { return true }
            open(target)
        default:
            return false
        }
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
