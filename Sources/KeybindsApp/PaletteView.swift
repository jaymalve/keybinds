import KeybindsCore
import SwiftUI

struct PaletteView: View {
    @Bindable var model: PaletteModel
    let onOpen: (PaletteRow) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = model.rows
        let selected = model.selectedIndex(in: rows)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps, windows, tabs and files", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            if model.browsing, case let extras = model.duplicateExtras, !extras.isEmpty {
                duplicatesBanner(extras.count)
            }

            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                rowView(row, selected: i == selected)
                                    .padding(.leading, row.indented ? 22 : 0)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpen(row) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedID) {
                        if let id = model.selectedID { proxy.scrollTo(id) }
                    }
                    .onChange(of: model.query) {
                        if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }

            Divider()

            HStack {
                if let message = model.message {
                    Text(message.text).foregroundStyle(message.key != nil ? .orange : .secondary)
                } else {
                    Text(summary)
                }
                Spacer()
                Text(hints(rows.indices.contains(selected) ? rows[selected] : nil))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { searchFocused = true }
    }

    @ViewBuilder private func rowView(_ row: PaletteRow, selected: Bool) -> some View {
        switch row.content {
        case .target(let result):
            ResultRow(result: result, copies: row.duplicates.count + 1, selected: selected,
                      favicon: model.favicons.image(forURL: result.target.url))
        case .site(let site, let members):
            SiteRow(site: site, members: members, expanded: model.expandedSites.contains(site), selected: selected,
                    favicon: model.favicons.image(forURL: members.first?.target?.url))
        }
    }

    private func duplicatesBanner(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square")
            Text("\(count) duplicate \(count == 1 ? "tab" : "tabs") open")
            Spacer()
            Text("⌘⇧⌫ closes the extra copies").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func hints(_ row: PaletteRow?) -> String {
        if case .site(let site, _)? = row?.content {
            return model.expandedSites.contains(site) ? "← collapse   ⌘⌫ close all   esc" : "→ expand   ⌘⌫ close all   esc"
        }
        if row?.target?.isFileSystem == true {
            return "↩ open   ⌘↩ show in Finder   ⌘⌫ trash   esc"
        }
        return "t/w/a/f␣ filter   ↩ open   ⌘⌫ close   ⌘Q quit   esc"
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
    /// Open copies of this page folded into the row.
    let copies: Int
    let selected: Bool
    let favicon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(result.target.title, result.titleMatches, base: .primary))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(highlighted(result.target.subtitle, result.subtitleMatches, base: .secondary))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if copies > 1 {
                Text("×\(copies)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("Open in \(copies) tabs")
            }
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

    /// Tabs with a favicon show it, with the browser's icon as a small badge.
    @ViewBuilder private var icon: some View {
        let appIcon = AppIcons.icon(for: result.target)
        if let favicon {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: favicon).resizable().interpolation(.high)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(width: 30, height: 30, alignment: .topLeading)
                    .padding([.top, .leading], 2)
                Image(nsImage: appIcon).resizable().frame(width: 15, height: 15)
            }
        } else {
            Image(nsImage: appIcon).resizable()
        }
    }

    private var badge: String {
        switch result.target.kind {
        case .app: if case .launch = result.target.locator { "Launch" } else { "App" }
        case .window: "Window"
        case .file: "File"
        case .folder: "Folder"
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

/// A website heading: several tabs of one site, folded together.
private struct SiteRow: View {
    let site: String
    let members: [PaletteRow]
    let expanded: Bool
    let selected: Bool
    let favicon: NSImage?

    var body: some View {
        let tabs = members.reduce(0) { $0 + $1.allTargets.count }
        let apps = Array(Set(members.compactMap(\.target?.appName))).sorted()
        HStack(spacing: 12) {
            Group {
                if let favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "globe").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(site).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(([tabs == 1 ? "1 tab" : "\(tabs) tabs"] + apps).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Site")
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
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for target: Target) -> NSImage {
        let key: String
        let make: () -> NSImage?
        if case .launch(let path) = target.locator {
            key = path
            make = { NSWorkspace.shared.icon(forFile: path) }
        } else if case .file(let path) = target.locator {
            key = path
            make = { NSWorkspace.shared.icon(forFile: path) }
        } else {
            key = "pid:\(target.pid)"
            make = { NSRunningApplication(processIdentifier: target.pid)?.icon }
        }
        if let cached = cache[key] { return cached }
        let icon = make() ?? NSWorkspace.shared.icon(for: .application)
        cache[key] = icon
        return icon
    }
}
