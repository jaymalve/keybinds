// Spike M0.1b: read Chromium's Favicons DB while the browser is running (immutable, read-only).
import Foundation
import SQLite3

let path = CommandLine.arguments[1]
var db: OpaquePointer?
let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)?immutable=1"
guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
    print("open failed: \(String(cString: sqlite3_errmsg(db)))"); exit(1)
}
let sql = """
SELECT m.page_url, b.width, length(b.image_data)
FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
WHERE b.width IN (16, 32) ORDER BY b.last_updated DESC LIMIT 5
"""
var stmt: OpaquePointer?
let t0 = Date()
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
    print("prepare failed: \(String(cString: sqlite3_errmsg(db)))"); exit(1)
}
var rows = 0
while sqlite3_step(stmt) == SQLITE_ROW {
    rows += 1
    let url = URL(string: String(cString: sqlite3_column_text(stmt, 0)))?.host ?? "?"
    print("  host=\(url) width=\(sqlite3_column_int(stmt, 1)) bytes=\(sqlite3_column_int(stmt, 2))")
}
var total: OpaquePointer?
sqlite3_prepare_v2(db, "SELECT count(*) FROM icon_mapping", -1, &total, nil)
sqlite3_step(total)
print(String(format: "rows shown=%d, total mappings=%d, query %.1f ms", rows, sqlite3_column_int(total, 0), Date().timeIntervalSince(t0) * 1000))
