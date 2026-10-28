import Foundation
import KeybindsCore
import OSLog

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "files")

/// Files and folders from Spotlight (no permission needed): recently used ones for the index, and a live
/// name search while typing. NSMetadataQuery runs on the main run loop.
@MainActor
public final class FileSearch {
    private var live: NSMetadataQuery?
    private var liveContinuation: CheckedContinuation<[Target], Never>?

    /// Recently used files go into the index, where they get full fuzzy matching.
    static let recentDays = 60
    static let recentLimit = 800
    static let liveLimit = 60

    public init() {}

    /// Files and folders opened in the last couple of months, most recently added first.
    func recent() async -> [Target] {
        let since = Date().addingTimeInterval(-Double(Self.recentDays) * 86_400)
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", since as NSDate)
        return await run(query, limit: Self.recentLimit)
    }

    /// Name search for every word of `text`. A newer search cancels the previous one, which returns [].
    public func search(_ text: String) async -> [Target] {
        cancelLive()
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        log.notice("spotlight search: \(words, privacy: .public)")
        // Word-start matching, like Finder's search: "plan" finds "implementation plan.md" but not
        // thousands of "explanation" files. Measured 120–220 ms for typical words.
        let clauses = words.map { word -> String in
            let safe = word.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
            return "kMDItemFSName == \"\(safe)*\"cdw"
        }
        guard let predicate = NSPredicate(fromMetadataQueryString: clauses.joined(separator: " && ")) else { return [] }
        let query = NSMetadataQuery()
        query.predicate = predicate
        live = query
        return await withCheckedContinuation { continuation in
            liveContinuation = continuation
            start(query, limit: Self.liveLimit) { [weak self] targets in
                guard let self, self.live === query else { return }
                self.live = nil
                self.liveContinuation = nil
                continuation.resume(returning: targets)
            }
        }
    }

    private func cancelLive() {
        live?.stop()
        live = nil
        liveContinuation?.resume(returning: [])
        liveContinuation = nil
    }

    private func run(_ query: NSMetadataQuery, limit: Int) async -> [Target] {
        await withCheckedContinuation { continuation in
            start(query, limit: limit) { continuation.resume(returning: $0) }
        }
    }

    /// Broad words ("ke") can match tens of thousands of files and take seconds to finish; take what has
    /// arrived by then. Results are ranked by our matcher afterwards, so completeness matters less than speed.
    static let timeLimit: Duration = .milliseconds(600)
    static let emptyTimeLimit: Duration = .seconds(3)

    private func start(_ query: NSMetadataQuery, limit: Int, done: @escaping @MainActor ([Target]) -> Void) {
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let start = Date()
        var finished = false
        var token: NSObjectProtocol?
        // Stop the query and keep the most recently added matches that aren't noise.
        let finish = {
            guard !finished else { return }
            finished = true
            query.disableUpdates()
            query.stop()
            if let token { NotificationCenter.default.removeObserver(token) }
            var found: [(Target, Date)] = []
            for i in 0..<query.resultCount {
                guard let item = query.result(at: i) as? NSMetadataItem, let t = Self.target(item) else { continue }
                found.append((t, t.added ?? .distantPast))
            }
            found.sort { $0.1 > $1.1 }
            log.notice("spotlight: \(query.resultCount, privacy: .public) results, kept \(found.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            done(found.prefix(limit).map(\.0))
        }
        // The observer fires on the main queue, where the query lives.
        nonisolated(unsafe) let finishOnMain = finish
        token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                       queue: .main) { _ in
            MainActor.assumeIsolated { finishOnMain() }
        }
        guard query.start() else {
            log.error("spotlight query failed to start")
            finish()
            return
        }
        // Cut a slow search short only once something has arrived; a busy Spotlight (indexing after a
        // build, say) can take over a second to return even a single match.
        Task { @MainActor in
            try? await Task.sleep(for: Self.timeLimit)
            var waited = Self.timeLimit
            while !finished, query.resultCount == 0, waited < Self.emptyTimeLimit {
                try? await Task.sleep(for: .milliseconds(100))
                waited += .milliseconds(100)
            }
            finish()
        }
    }

    /// When the item arrived in its folder; older volumes lack the attribute, so fall back to creation.
    private static func added(_ item: NSMetadataItem) -> Date? {
        item.value(forAttribute: "kMDItemDateAdded") as? Date
            ?? item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
    }

    /// Skips noise: hidden paths, Library, app bundles and their insides, build output, dependencies.
    private static let skippedParts = ["/Library/", "/node_modules/", "/DerivedData/", "/Pods/", "/vendor/", "/__pycache__/",
                                       "/target/debug/", "/target/release/", "/build/", "/dist/"]

    private static func target(_ item: NSMetadataItem) -> Target? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/"), !path.contains("/."), !path.contains(".app/"), !path.hasSuffix(".app"),
              !skippedParts.contains(where: path.contains) else { return nil }
        let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let isFolder = contentType == "public.folder"
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let shortParent = parent == home ? "~" : "~" + parent.dropFirst(home.count)
        return Target(kind: isFolder ? .folder : .file, title: name, subtitle: shortParent,
                      appName: "Finder", bundleID: nil, pid: 0, locator: .file(path: path), added: added(item))
    }
}
