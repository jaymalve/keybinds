import AppKit
import SwiftUI

@MainActor
@Observable
final class PaletteModel {
    var query = ""
    /// Bumped on every show so the view can re-focus the search field.
    var showCount = 0
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 680, height: 420)

    private let model = PaletteModel()
    private lazy var panel: PalettePanel = makePanel()
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.query = ""
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

        let hosting = NSHostingView(rootView: PaletteView(model: model))
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

    /// Esc closes. Arrow keys and Enter land here in M2.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated { self?.handleKey(keyCode) ?? false }
            return consumed ? nil : event
        }
    }

    /// Returns true when the key was handled and shouldn't reach the search field.
    private func handleKey(_ keyCode: UInt16) -> Bool {
        guard panel.isKeyWindow else { return false }
        switch keyCode {
        case 53:  // kVK_Escape
            hide()
            return true
        default:
            return false
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
