import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openPalette: () -> Void
    private let showSettings: () -> Void
    private let showPermissions: () -> Void

    init(openPalette: @escaping () -> Void, showSettings: @escaping () -> Void, showPermissions: @escaping () -> Void) {
        self.openPalette = openPalette
        self.showSettings = showSettings
        self.showPermissions = showPermissions
        super.init()

        let image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "Keybinds")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Palette  (⇧⇧)", action: #selector(openPaletteAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(permissionsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keybinds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func openPaletteAction() { openPalette() }
    @objc private func settingsAction() { showSettings() }
    @objc private func permissionsAction() { showPermissions() }
}
