import KeybindsCore
import SwiftUI

struct PaletteView: View {
    @Bindable var model: PaletteModel
    let onOpen: (Target) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps, windows and tabs", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            if results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, result in
                                ResultRow(result: result, selected: i == model.selection)
                                    .id(result.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpen(result.target) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) {
                        guard results.indices.contains(model.selection) else { return }
                        proxy.scrollTo(results[model.selection].id)
                    }
                    .onChange(of: model.query) {
                        if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }

            Divider()

            HStack {
                Text(summary)
                Spacer()
                Text("↑↓ select   ↩ open   ⇧⇧ / esc close")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { searchFocused = true }
    }

    private var summary: String {
        let targets = model.index.targets
        let tabs = targets.filter { $0.kind == .browserTab || $0.kind == .terminalTab }.count
        let windows = targets.filter { $0.kind == .window }.count
        let apps = Set(targets.map(\.pid)).count
        return "\(tabs) tabs · \(windows) windows · \(apps) apps"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "hourglass" : "questionmark.square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "Indexing…" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ResultRow: View {
    let result: RankedTarget
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIcons.icon(for: result.target.pid))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(result.target.title, result.titleMatches, base: .primary))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(highlighted(result.target.subtitle, result.subtitleMatches, base: .secondary))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(badge)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var badge: String {
        switch result.target.kind {
        case .app: "App"
        case .window: "Window"
        case .browserTab, .terminalTab: "Tab"
        }
    }

    /// Bolds matched characters.
    private func highlighted(_ text: String, _ positions: [Int], base: Color) -> AttributedString {
        var result = AttributedString()
        let matched = Set(positions)
        for (i, c) in text.enumerated() {
            var piece = AttributedString(String(c))
            piece.foregroundColor = base
            if matched.contains(i) {
                piece.font = .system(size: 14, weight: .bold)
                piece.foregroundColor = .primary
            }
            result += piece
        }
        return result
    }
}

@MainActor
enum AppIcons {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage {
        if let cached = cache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
        cache[pid] = icon
        return icon
    }
}
