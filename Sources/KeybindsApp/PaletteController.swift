import AppKit
import KeybindsCore
import KeybindsPlatform
import SwiftUI

@MainActor
@Observable
final class PaletteModel {
    static let maxRows = 80

    /// A line in the footer: a question ("press ⌘⌫ again…") or a result. `key` identifies what a
    /// repeated keypress would confirm.
    struct Message {
        let key: String?
        let text: String
    }

    let index: TargetIndex
    let favicons: FaviconStore
    var query = "" { didSet { selectedID = nil; message = nil; searchFilesLive() } }
    /// The selected row, by identity: rows reorder while scans land, and an index would drift onto a neighbor.
    /// nil means "the first row".
    var selectedID: String? { didSet { if selectedID != oldValue, message?.key != nil { message = nil } } }
    /// Bumped on every show so the view can re-focus the search field.
    var showCount = 0
    var message: Message?
    /// Settings → group tabs by website and fold duplicates.
    var groupTabs = false
    var expandedSites = Set<String>()
    /// Settings → search files and folders.
    var searchFiles = true
    /// Spotlight results for the current words, re-ranked by the fuzzy matcher on every keystroke.
    private var liveFiles = SearchIndex([])
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    init(index: TargetIndex, favicons: FaviconStore) {
        self.index = index
        self.favicons = favicons
    }

    var browsing: Bool { SearchIndex.isBrowsing(query) }

    var rows: [PaletteRow] {
        var results = index.search.search(query)
        if !browsing { results = SearchIndex.merge(results, liveFiles.search(query)) }
        // Browsing without a scope keeps its order: the previous target first, then by use.
        if !browsing || SearchIndex.parse(query).kinds != nil { results = SearchIndex.filesByDateAdded(results) }
        let rows = PaletteRows.build(results, collapseDuplicates: groupTabs,
                                     groupBySite: groupTabs && browsing, expanded: expandedSites)
        return Array(rows.prefix(Self.maxRows))
    }

    /// Every copy of a page except the most recent one, across all open tabs.
    var duplicateExtras: [Target] {
        PaletteRows.duplicateTabs(index.targets).flatMap { $0.dropFirst() }
    }

    /// Spotlight finds files by name beyond the recently used ones already in the index. Debounced; earlier
    /// results stay until new ones land, so the list doesn't flicker.
    private func searchFilesLive() {
        liveTask?.cancel()
        let (kinds, text) = SearchIndex.parse(query)
        let words = text.trimmingCharacters(in: .whitespaces)
        guard searchFiles, kinds?.contains(.file) ?? true, words.count >= 2 else {
            liveFiles = SearchIndex([])
            return
        }
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let files = await index.fileSearch.search(words)
            guard !Task.isCancelled else { return }
            liveFiles = SearchIndex(files, frecency: { [index] in index.frecency($0) })
        }
    }

    func selectedIndex(in rows: [PaletteRow]) -> Int {
        selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    var selectedRow: PaletteRow? {
        let rows = rows
        return rows.isEmpty ? nil : rows[selectedIndex(in: rows)]
    }

    func moveSelection(by delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let next = (selectedIndex(in: rows) + delta + rows.count) % rows.count
        selectedID = rows[next].id
    }

    /// Before rows disappear, move the selection to the next row that stays (or the previous one).
    func selectNeighbor(removing ids: Set<String>) {
        let rows = rows
        let current = selectedIndex(in: rows)
        guard rows.indices.contains(current), ids.contains(rows[current].id) else { return }
        let after = rows[(current + 1)...].first { !ids.contains($0.id) }
        let before = rows[..<current].last { !ids.contains($0.id) }
        selectedID = (after ?? before)?.id
    }

    func setExpanded(_ site: String, _ expanded: Bool) {
        if expanded { expandedSites.insert(site) } else { expandedSites.remove(site) }
        selectedID = "site:\(site)"
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 680, height: 420)

    private let model: PaletteModel
    private let activator: Activator
    private let closer: Closer
    private lazy var panel: PalettePanel = makePanel()
    private var keyMonitor: Any?
    var onOpenSettings: () -> Void = {}

    init(index: TargetIndex, favicons: FaviconStore) {
        model = PaletteModel(index: index, favicons: favicons)
        activator = Activator(index: index)
        closer = Closer(index: index)
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    func apply(_ settings: KeybindsCore.Settings) {
        model.groupTabs = settings.groupTabs
        model.searchFiles = settings.searchFiles
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.index.refresh()
        model.query = ""
        model.selectedID = nil
        model.message = nil
        model.expandedSites = []
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

        let hosting = NSHostingView(rootView: PaletteView(model: model) { [weak self] row in
            self?.open(row)
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

    /// Hide first so the panel gives up key focus before the target takes it. A website heading
    /// opens and closes instead.
    private func open(_ row: PaletteRow) {
        switch row.content {
        case .target(let r):
            hide()
            activator.activate(r.target)
        case .site(let site, _):
            model.setExpanded(site, !model.expandedSites.contains(site))
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let control = event.modifierFlags.contains(.control)
            let command = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let consumed = MainActor.assumeIsolated {
                self?.handleKey(keyCode, control: control, command: command, shift: shift) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// Returns true when the key was handled and shouldn't reach the search field.
    private func handleKey(_ keyCode: UInt16, control: Bool, command: Bool, shift: Bool) -> Bool {
        guard panel.isKeyWindow else { return false }
        if command {
            switch (keyCode, shift) {
            case (43, _):  // ⌘,
                hide()
                onOpenSettings()
            // ⌘⌫ closes whatever is selected (tab or window); it replaces the field's delete-to-start-of-line.
            case (51, true): closeDuplicates()  // ⌘⇧⌫
            case (51, false): closeSelected()   // ⌘⌫
            case (12, false): quitSelected()    // ⌘Q
            case (36, _), (76, _): revealSelected()  // ⌘↩
            default: return false  // ⌘A, ⌘C, ⌘V… go to the search field
            }
            return true
        }
        switch (keyCode, control) {
        case (53, _):  // Esc
            hide()
        case (125, _), (45, true):  // ↓, ⌃N
            model.moveSelection(by: 1)
        case (126, _), (35, true):  // ↑, ⌃P
            model.moveSelection(by: -1)
        case (36, _), (76, _):  // Return, keypad Enter
            if let row = model.selectedRow { open(row) }
        case (124, _), (123, _):  // → ←: open and close website groups; otherwise move the text cursor
            return expandOrCollapse(right: keyCode == 124)
        default:
            return false
        }
        return true
    }

    private func expandOrCollapse(right: Bool) -> Bool {
        guard let row = model.selectedRow else { return false }
        switch row.content {
        case .site(let site, _):
            guard right != model.expandedSites.contains(site) else { return false }
            model.setExpanded(site, right)
        case .target(let r):
            guard !right, row.indented, let site = r.target.siteKey else { return false }
            model.setExpanded(site, false)
        }
        return true
    }

    // MARK: - Close and quit

    private func closeSelected() {
        guard let row = model.selectedRow else { return }
        switch row.content {
        case .site(let site, _):
            let targets = row.allTargets
            guard confirm("close:\(row.id)", "Press ⌘⌫ again to close all \(targets.count) \(site) tabs") else { return }
            close(targets, rowIDs: [row.id])
        case .target(let r):
            let target = r.target
            if target.isFileSystem {
                guard confirm("trash:\(row.id)", "Press ⌘⌫ again to move “\(target.title)” to the Trash") else { return }
                close([target], rowIDs: [row.id])
                return
            }
            if target.kind == .app {
                NSSound.beep()
                model.message = PaletteModel.Message(key: nil, text: "Apps can't be closed with ⌘⌫. ⌘Q quits \(target.appName).")
                return
            }
            if closer.busyProcess(target) != nil {
                // Terminal asks before ending a running process: switch to the tab so its question is visible.
                hide()
                activator.activate(target)
                Task { _ = await closer.close(target) }
                return
            }
            close([target], rowIDs: [row.id])
        }
    }

    /// Keeps the most recent copy of each page and closes the rest.
    private func closeDuplicates() {
        // Safari tabs are found by index: close from the end of each window so earlier indexes don't shift.
        let extras = model.duplicateExtras.sorted { a, b in
            if case .safariTab(let wa, let ia, _) = a.locator, case .safariTab(let wb, let ib, _) = b.locator, wa == wb {
                return ia > ib
            }
            return false
        }
        guard !extras.isEmpty else { NSSound.beep(); return }
        close(extras, rowIDs: Set(extras.map(\.id)))
    }

    /// ⌘↩ on a file or folder: show it in Finder instead of opening it.
    private func revealSelected() {
        guard let target = model.selectedRow?.target, target.isFileSystem else { NSSound.beep(); return }
        hide()
        _ = activator.reveal(target)
    }

    private func quitSelected() {
        guard let target = model.selectedRow?.allTargets.first, target.pid > 0, !target.isFileSystem else { NSSound.beep(); return }
        guard confirm("quit:\(target.pid)", "Press ⌘Q again to quit \(target.appName)") else { return }
        let all = model.index.targets.filter { $0.pid == target.pid }
        model.selectNeighbor(removing: Set(all.map(\.id)))
        model.index.hide(all)
        model.index.closeFinished(all, closed: closer.quit(pid: target.pid))
    }

    /// Hides the rows right away, then closes one by one in the background.
    private func close(_ targets: [Target], rowIDs: Set<String>) {
        model.selectNeighbor(removing: rowIDs)
        model.index.hide(targets)
        Task {
            var closed: [Target] = [], failed: [Target] = []
            for target in targets {
                if await closer.close(target) { closed.append(target) } else { failed.append(target) }
            }
            model.index.closeFinished(closed, closed: true)
            model.index.closeFinished(failed, closed: false)
            if !failed.isEmpty {
                let what = failed.count == 1 ? "“\(failed[0].title)”" : "\(failed.count) items"
                model.message = PaletteModel.Message(key: nil, text: "Couldn't close \(what)")
            }
        }
    }

    /// Destructive actions need the same key twice in a row; the first press explains what will happen.
    private func confirm(_ key: String, _ question: String) -> Bool {
        if model.message?.key == key {
            model.message = nil
            return true
        }
        model.message = PaletteModel.Message(key: key, text: question)
        return false
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
