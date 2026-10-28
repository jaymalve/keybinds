import AppKit
import KeybindsCore
import SwiftUI

/// Settings shared by the window and the app. Every change is saved and applied immediately.
@MainActor
@Observable
final class SettingsModel {
    var settings: KeybindsCore.Settings {
        didSet {
            guard settings != oldValue else { return }
            do { try store.save(settings) } catch {
                Log.app.error("saving settings failed: \(error.localizedDescription, privacy: .public)")
            }
            onChange(settings)
        }
    }
    var recording = false {
        didSet { onRecordingChange(recording) }
    }
    var comboError: String?

    @ObservationIgnored let store: SettingsStore
    @ObservationIgnored var onChange: (KeybindsCore.Settings) -> Void = { _ in }
    @ObservationIgnored var onRecordingChange: (Bool) -> Void = { _ in }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        do {
            settings = try store.load()
        } catch {
            Log.app.error("settings.json unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            settings = KeybindsCore.Settings.default
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Keybinds Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        return window
    }()

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Open the palette") {
                Toggle("Double-tap Shift", isOn: $model.settings.doubleShiftEnabled)
                if model.settings.doubleShiftEnabled {
                    LabeledContent("Longest tap") {
                        Slider(value: ms(\.maxHold), in: 100...400, step: 10)
                        Text("\(Int(model.settings.doubleTap.maxHold * 1000)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    LabeledContent("Longest pause between taps") {
                        Slider(value: ms(\.maxGap), in: 150...600, step: 10)
                        Text("\(Int(model.settings.doubleTap.maxGap * 1000)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Keyboard shortcut") {
                    ShortcutRecorder(combo: $model.settings.paletteCombo, recording: $model.recording)
                }
                if let error = model.comboError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                if model.settings.paletteCombo != nil {
                    ExcludedApps(bundleIDs: $model.settings.comboExcludedBundleIDs)
                }
            }

            Section("Tabs") {
                sourceToggle("Chrome, Brave, Edge and Vivaldi tabs", "chromium")
                sourceToggle("Safari tabs", "safari")
                sourceToggle("Terminal tabs", "terminal")
                Text("Apps with tabs switched off show their windows instead.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Group tabs by website", isOn: $model.settings.groupTabs)
                Text("Websites with several tabs show as one row you can expand (→). Copies of the same page fold into one row.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Apps") {
                Toggle("Include installed apps that aren't running", isOn: $model.settings.showNotRunningApps)
            }

            Section {
                Text(model.store.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private func ms(_ key: WritableKeyPath<DoubleTapTiming, TimeInterval>) -> Binding<Double> {
        Binding(get: { model.settings.doubleTap[keyPath: key] * 1000 },
                set: { model.settings.doubleTap[keyPath: key] = $0 / 1000 })
    }

    private func sourceToggle(_ title: String, _ source: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !model.settings.disabledTabSources.contains(source) },
            set: { on in
                if on { model.settings.disabledTabSources.remove(source) } else { model.settings.disabledTabSources.insert(source) }
            }))
    }
}

/// Click, then press a combo with ⌘, ⌥ or ⌃. Esc cancels.
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @Binding var recording: Bool
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Press shortcut…" : (combo?.displayString ?? "Record Shortcut")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 130)
            if combo != nil && !recording {
                Button("Clear") { combo = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let label = Self.label(keyCode: keyCode, characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated {
                if keyCode == 53 { stop(); return }  // Esc
                var mods = Set<KeyCombo.Modifier>()
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.control) { mods.insert(.control) }
                if flags.contains(.shift) { mods.insert(.shift) }
                // Shift alone would steal ordinary typing.
                guard !mods.subtracting([.shift]).isEmpty else { NSSound.beep(); return }
                combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: mods, keyLabel: label)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private static func label(keyCode: UInt16, characters: String?) -> String {
        let named: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→",
                                       125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘"]
        return named[keyCode] ?? (characters?.uppercased() ?? "?")
    }
}

/// Apps where the keyboard shortcut is released so the app itself receives it.
private struct ExcludedApps: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Let these apps keep the shortcut").font(.callout)
            ForEach(bundleIDs, id: \.self) { id in
                HStack {
                    Image(nsImage: icon(id)).resizable().frame(width: 16, height: 16)
                    Text(name(id))
                    Spacer()
                    Button { bundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add App…", action: add)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(id) { bundleIDs.append(id) }
        }
    }

    private func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    private func name(_ id: String) -> String {
        url(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
    private func icon(_ id: String) -> NSImage {
        url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }
}
