import AppKit
import Observation
import OSLog
import SQLite3

private let log = Logger(subsystem: "com.jaymalve.keybinds", category: "favicons")

/// Favicons by host. Local-first: Chromium browsers' own Favicons databases (all profiles); otherwise
/// fetched directly from the site (never a third-party favicon service) and cached on disk.
@MainActor
@Observable
public final class FaviconStore {
    /// Read by views, so a favicon arriving re-renders its row.
    public private(set) var images: [String: NSImage] = [:]

    @ObservationIgnored private var requested = Set<String>()
    @ObservationIgnored private let chromium: Task<[String: Data], Never>
    @ObservationIgnored private let cacheDir: URL

    nonisolated static let cacheMaxAge: TimeInterval = 7 * 24 * 3600

    public init() {
        cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keybinds/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        chromium = Task.detached(priority: .utility) { ChromiumFavicons.load() }
    }

    /// Returns the cached favicon, or nil and starts loading it.
    public func image(forURL url: String?) -> NSImage? {
        guard let url, let host = URL(string: url)?.host()?.lowercased(),
              url.hasPrefix("http") else { return nil }
        if let image = images[host] { return image }
        if requested.insert(host).inserted { load(host) }
        return nil
    }

    private func load(_ host: String) {
        let cacheDir = self.cacheDir
        Task {
            let local = await chromium.value[host]
            let data = await Task.detached(priority: .utility) { () -> Data? in
                if let local { return local }
                return await FaviconFetcher.cachedOrFetch(host: host, cacheDir: cacheDir)
            }.value
            if let data, let image = NSImage(data: data) {
                images[host] = image
            }
        }
    }
}

enum ChromiumFavicons {
    static let browserDirs = ["Google/Chrome", "Google/Chrome Beta", "BraveSoftware/Brave-Browser",
                              "Microsoft Edge", "Vivaldi"]

    /// host → best bitmap across every profile of every Chromium browser (prefer 32px, then 16px, newest).
    static func load() -> [String: Data] {
        let start = Date()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var best: [String: (rank: Int, updated: Int64, data: Data)] = [:]
        var files = 0
        for dir in browserDirs {
            let root = support.appendingPathComponent(dir)
            for profile in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let db = root.appendingPathComponent(profile).appendingPathComponent("Favicons").path
                guard FileManager.default.fileExists(atPath: db) else { continue }
                files += 1
                read(db) { host, rank, updated, data in
                    if let cur = best[host], (cur.rank, cur.updated) >= (rank, updated) { return }
                    best[host] = (rank, updated, data)
                }
            }
        }
        log.debug("chromium favicons: \(best.count) hosts from \(files) profiles in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return best.mapValues(\.data)
    }

    /// Opened immutable and read-only: works while the browser holds its lock (spike M0.1b).
    private static func read(_ path: String, _ row: (String, Int, Int64, Data) -> Void) {
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT m.page_url, b.width, b.last_updated, b.image_data
        FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(stmt, 0),
                  let host = URL(string: String(cString: urlText))?.host()?.lowercased(),
                  let blob = sqlite3_column_blob(stmt, 3) else { continue }
            let width = Int(sqlite3_column_int(stmt, 1))
            let rank = width == 32 ? 3 : width == 16 ? 2 : width > 32 ? 1 : 0
            row(host, rank, sqlite3_column_int64(stmt, 2), Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3))))
        }
    }
}

/// Fetches a site's favicon from the site itself: `<link rel="icon">` from its home page, else /favicon.ico.
/// No cookies, short timeouts. Misses are remembered so a host isn't retried for a week.
enum FaviconFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    static func cachedOrFetch(host: String, cacheDir: URL) async -> Data? {
        let file = cacheDir.appendingPathComponent(host)
        let miss = cacheDir.appendingPathComponent(host + ".none")
        let fm = FileManager.default
        for url in [file, miss] {
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let modified = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < FaviconStore.cacheMaxAge {
                return url == file ? try? Data(contentsOf: file) : nil
            }
        }
        // Local names and IPs (dev servers, routers) aren't worth a request.
        guard host.contains("."), host.rangeOfCharacter(from: .letters) != nil else { return nil }

        if let data = await fetch(host: host) {
            try? data.write(to: file, options: .atomic)
            try? fm.removeItem(at: miss)
            return data
        }
        fm.createFile(atPath: miss.path, contents: nil)
        return nil
    }

    private static func fetch(host: String) async -> Data? {
        guard let home = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: home), let html = String(data: data.prefix(256_000), encoding: .utf8) {
            candidates += iconLinks(in: html, base: response.url ?? home)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))
        for url in candidates {
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil {
                return data
            }
        }
        return nil
    }

    /// hrefs of `<link rel="…icon…">`, best guesses first (apple-touch-icon is usually largest).
    private static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let relRegex = try? NSRegularExpression(pattern: "rel\\s*=\\s*[\"']([^\"']*)[\"']", options: .caseInsensitive),
              let hrefRegex = try? NSRegularExpression(pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive)
        else { return [] }
        let ns = html as NSString
        var found: [(Int, URL)] = []
        for match in linkRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let tagNS = tag as NSString
            guard let rel = relRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length))
                    .map({ tagNS.substring(with: $0.range(at: 1)).lowercased() }), rel.contains("icon"),
                  let href = hrefRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length))
                    .map({ tagNS.substring(with: $0.range(at: 1)) }),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            found.append((rel.contains("apple-touch") ? 0 : 1, url))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
