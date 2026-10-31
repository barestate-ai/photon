import Foundation
import SQLite3

extension Store {
  /// History is keyed by URL: a revisit adds one visit and keeps the newest non-empty title.
  public func recordVisit(url: String, title: String, at time: Double) throws {
    try run(
      """
      INSERT INTO history(url, title, visits, last_visit) VALUES (?1, ?2, 1, ?3)
      ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last_visit = ?3,
        title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
      """
    ) { statement in
      sqlite3_bind_text(statement, 1, url, -1, Self.transient)
      sqlite3_bind_text(statement, 2, title, -1, Self.transient)
      sqlite3_bind_double(statement, 3, time)
    }
  }

  /// A page is bookmarked once: a second add changes nothing. Returns whether this call added it.
  public func addBookmark(url: String, title: String, at time: Double) throws -> Bool {
    guard !bookmarkExists(url) else { return false }
    try run("INSERT INTO bookmarks(url, title, created_at) VALUES (?1, ?2, ?3)") { statement in
      sqlite3_bind_text(statement, 1, url, -1, Self.transient)
      sqlite3_bind_text(statement, 2, title, -1, Self.transient)
      sqlite3_bind_double(statement, 3, time)
    }
    return true
  }

  public func recentSites(limit: Int) -> [HistoryRow] {
    var statement: OpaquePointer?
    let sql =
      "SELECT url, title, visits, last_visit FROM history ORDER BY last_visit DESC, url ASC LIMIT ?1"
    guard let db = openDB, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(limit))
    var rows: [HistoryRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append(
        HistoryRow(
          url: String(cString: sqlite3_column_text(statement, 0)),
          title: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
          visits: Int(sqlite3_column_int64(statement, 2)),
          lastVisit: sqlite3_column_double(statement, 3)))
    }
    return rows
  }

  /// Newest first, ties by address, so the same data always lists in the same order.
  public func allBookmarks() -> [BookmarkRow] {
    var statement: OpaquePointer?
    let sql = "SELECT url, title, created_at FROM bookmarks ORDER BY created_at DESC, url ASC"
    guard let db = openDB, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [BookmarkRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append(
        BookmarkRow(
          url: String(cString: sqlite3_column_text(statement, 0)),
          title: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
          createdAt: sqlite3_column_double(statement, 2)))
    }
    return rows
  }

  private func bookmarkExists(_ url: String) -> Bool {
    var statement: OpaquePointer?
    guard let db = openDB,
      sqlite3_prepare_v2(db, "SELECT 1 FROM bookmarks WHERE url = ?1", -1, &statement, nil)
        == SQLITE_OK
    else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, url, -1, Self.transient)
    return sqlite3_step(statement) == SQLITE_ROW
  }
}
