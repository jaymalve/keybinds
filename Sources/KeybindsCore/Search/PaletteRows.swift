import Foundation

/// One line in the palette: a target, or a website heading that folds several tabs together.
public struct PaletteRow: Identifiable, Sendable {
    public enum Content: Sendable {
        case target(RankedTarget)
        /// Tabs from one website; `members` are in result order.
        case site(String, members: [PaletteRow])
    }

    public let id: String
    public let content: Content
    /// Shown inside an expanded site.
    public let indented: Bool
    /// Other open copies of the same page, folded into this row.
    public let duplicates: [Target]

    public var target: Target? {
        if case .target(let r) = content { r.target } else { nil }
    }

    /// Every tab this row stands for, including folded duplicates and a site's members.
    public var allTargets: [Target] {
        switch content {
        case .target(let r): [r.target] + duplicates
        case .site(_, let members): members.flatMap(\.allTargets)
        }
    }
}

public enum PaletteRows {
    /// Turns search results into rows. Duplicates fold into the first (most recent) copy. With
    /// `groupBySite`, websites with two or more tabs become one heading, placed where its first tab
    /// was; `expanded` lists the sites whose tabs are shown under the heading.
    public static func build(_ results: [RankedTarget], collapseDuplicates: Bool, groupBySite: Bool,
                             expanded: Set<String>) -> [PaletteRow] {
        var rows: [(RankedTarget, [Target])] = []
        if collapseDuplicates {
            var firstByPage: [String: Int] = [:]
            for r in results {
                if let page = r.target.pageKey {
                    if let i = firstByPage[page] { rows[i].1.append(r.target); continue }
                    firstByPage[page] = rows.count
                }
                rows.append((r, []))
            }
        } else {
            rows = results.map { ($0, []) }
        }

        func item(_ r: RankedTarget, _ dups: [Target], indented: Bool) -> PaletteRow {
            PaletteRow(id: r.id, content: .target(r), indented: indented, duplicates: dups)
        }
        guard groupBySite else { return rows.map { item($0.0, $0.1, indented: false) } }

        let counts = Dictionary(rows.compactMap { $0.0.target.siteKey }.map { ($0, 1) }, uniquingKeysWith: +)
        var members: [String: [PaletteRow]] = [:]
        for (r, dups) in rows {
            if let site = r.target.siteKey, counts[site, default: 0] > 1 {
                members[site, default: []].append(item(r, dups, indented: true))
            }
        }
        var out: [PaletteRow] = []
        var emitted = Set<String>()
        for (r, dups) in rows {
            guard let site = r.target.siteKey, let group = members[site] else {
                out.append(item(r, dups, indented: false))
                continue
            }
            guard emitted.insert(site).inserted else { continue }
            out.append(PaletteRow(id: "site:\(site)", content: .site(site, members: group), indented: false, duplicates: []))
            if expanded.contains(site) { out += group }
        }
        return out
    }

    /// Every set of tabs showing the same page, most recent copy first.
    public static func duplicateTabs(_ targets: [Target]) -> [[Target]] {
        var groups: [String: [Target]] = [:]
        var order: [String] = []
        for t in targets {
            guard let page = t.pageKey else { continue }
            if groups[page] == nil { order.append(page) }
            groups[page, default: []].append(t)
        }
        return order.compactMap { groups[$0]!.count > 1 ? groups[$0] : nil }
    }
}
