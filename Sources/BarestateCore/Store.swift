import Foundation
import SQLite3

/// The single SQLite connection (architecture §3): one actor owns it, WAL mode, synchronous=NORMAL.
public actor Store {
  public struct Failure: Error {
    public let message: String
  }

  nonisolated(unsafe) let db: OpaquePointer

  public init(path: String) throws {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let handle
    else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      sqlite3_close(handle)
      throw Failure(message: message)
    }
    for statement in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", Self.schema] {
      var error: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(handle, statement, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "sqlite error"
        sqlite3_free(error)
        sqlite3_close(handle)
        throw Failure(message: message)
      }
    }
    // A data directory made before `rung` existed has the table without it; a fresh one already
    // has it, and the duplicate-column error is the expected answer.
    sqlite3_exec(handle, "ALTER TABLE actions ADD COLUMN rung TEXT", nil, nil, nil)
    db = handle
  }

  private var closed = false

  /// Every SQL entry point reads the connection here: a Task that outlives `close()` must find
  /// nothing, not a freed pointer.
  var openDB: OpaquePointer? { closed ? nil : db }

  deinit {
    if !closed { Self.closeHandle(db) }
  }

  /// Checkpoints and closes the connection. Quitting calls this instead of waiting for the last
  /// reference to go: a Task still suspended when the message loop ends is never resumed and
  /// keeps the Store alive. Nothing may use the Store afterwards.
  public func close() {
    guard !closed else { return }
    closed = true
    Self.closeHandle(db)
  }

  private static func closeHandle(_ db: OpaquePointer) {
    // This platform's SQLite keeps the -wal/-shm files after the last close unless told not to.
    var persist: Int32 = 0
    sqlite3_file_control(db, nil, SQLITE_FCNTL_PERSIST_WAL, &persist)
    sqlite3_close(db)
  }

  public func tableNames() -> [String] {
    query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
  }

  public struct HistoryRow: Sendable {
    public let url: String
    public let title: String
    public let visits: Int
    public let lastVisit: Double

    public init(url: String, title: String, visits: Int, lastVisit: Double) {
      self.url = url
      self.title = title
      self.visits = visits
      self.lastVisit = lastVisit
    }
  }

  public struct BookmarkRow: Sendable {
    public let url: String
    public let title: String
    public let createdAt: Double

    public init(url: String, title: String, createdAt: Double) {
      self.url = url
      self.title = title
      self.createdAt = createdAt
    }
  }

  /// Replaces rows with the same url, so seeding twice ends in the same state.
  public func seed(history: [HistoryRow], bookmarks: [BookmarkRow]) throws {
    for row in history {
      try run(
        "INSERT OR REPLACE INTO history(url, title, visits, last_visit) VALUES (?1, ?2, ?3, ?4)"
      ) { statement in
        sqlite3_bind_text(statement, 1, row.url, -1, Self.transient)
        sqlite3_bind_text(statement, 2, row.title, -1, Self.transient)
        sqlite3_bind_int64(statement, 3, Int64(row.visits))
        sqlite3_bind_double(statement, 4, row.lastVisit)
      }
    }
    for row in bookmarks {
      try run("INSERT OR REPLACE INTO bookmarks(url, title, created_at) VALUES (?1, ?2, ?3)") {
        statement in
        sqlite3_bind_text(statement, 1, row.url, -1, Self.transient)
        sqlite3_bind_text(statement, 2, row.title, -1, Self.transient)
        sqlite3_bind_double(statement, 3, row.createdAt)
      }
    }
  }

  public enum Table: String, Sendable {
    case history, bookmarks
  }

  public func rowCount(_ table: Table) -> Int {
    Int(query("SELECT count(*) FROM \(table.rawValue)").first ?? "") ?? 0
  }

  static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
    guard let db = openDB else { throw Failure(message: "the store is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Failure(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw Failure(message: String(cString: sqlite3_errmsg(db)))
    }
  }

  public func journalMode() -> String {
    query("PRAGMA journal_mode").first ?? ""
  }

  private func query(_ sql: String) -> [String] {
    var statement: OpaquePointer?
    guard let db = openDB, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append(String(cString: sqlite3_column_text(statement, 0)))
    }
    return rows
  }

  /// Call once this process owns the data directory. A `pending` row belongs to a run that is gone:
  /// its page is gone too, so nothing can prove the effect, and a write is never retried. A
  /// `quoted` row can no longer be approved, and nothing of it was dispatched. Returns how many
  /// rows were closed.
  @discardableResult
  public nonisolated func reconcile() throws -> Int {
    let sql = """
      UPDATE actions SET
        state = CASE state WHEN 'pending' THEN 'outcome-unknown' ELSE 'cancelled' END,
        reason = CASE state WHEN 'pending' THEN 'app-restarted: effect unproven, never retried'
          ELSE 'app-restarted: approval lost' END,
        updated_at = strftime('%s', 'now') WHERE state IN ('pending', 'quoted')
      """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(message: String(cString: sqlite3_errmsg(db)))
    }
    return Int(sqlite3_changes(db))
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS actions(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL,
      client_action_id TEXT NOT NULL, tab_id TEXT, epoch INTEGER, observation_id TEXT, kind TEXT,
      target TEXT, text_hash TEXT,
      state TEXT NOT NULL CHECK(state IN
        ('quoted','pending','confirmed','failed','cancelled','outcome-unknown')),
      sensitive INTEGER, approval_token_hash TEXT, dom_verdict TEXT, model_verdict TEXT,
      reason TEXT, created_at REAL, updated_at REAL, rung TEXT,
      UNIQUE(session_id, client_action_id));
    CREATE TABLE IF NOT EXISTS history(url TEXT PRIMARY KEY, title TEXT, visits INTEGER,
      last_visit REAL);
    CREATE TABLE IF NOT EXISTS bookmarks(url TEXT PRIMARY KEY, title TEXT, created_at REAL);
    CREATE TABLE IF NOT EXISTS canvas_nodes(id TEXT PRIMARY KEY, tab_id TEXT, url TEXT NOT NULL,
      title TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, archived INTEGER NOT NULL,
      updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS canvas_edges(from_id TEXT NOT NULL, to_id TEXT NOT NULL,
      kind TEXT NOT NULL, run_id TEXT NOT NULL DEFAULT '', PRIMARY KEY(from_id, to_id, kind, run_id));
    CREATE TABLE IF NOT EXISTS canvas_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """
}
