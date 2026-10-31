import Foundation
import SQLite3

extension Store {
  /// Replaces the saved canvas in one transaction, so a reader never sees half of it and a save
  /// costs one commit however many nodes it holds.
  public func saveCanvas(_ graph: PageGraph) throws {
    guard let db = openDB else { throw Failure(message: "the store is closed") }
    try exec(db, "BEGIN IMMEDIATE")
    do {
      for table in ["canvas_nodes", "canvas_edges", "canvas_meta"] {
        try run("DELETE FROM \(table)") { _ in }
      }
      for node in graph.nodes {
        try run(
          """
          INSERT INTO canvas_nodes(id, tab_id, url, title, x, y, archived, updated_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
          """
        ) { statement in
          sqlite3_bind_text(statement, 1, node.id, -1, Self.transient)
          if let tab = node.tabId {
            sqlite3_bind_text(statement, 2, tab, -1, Self.transient)
          } else {
            sqlite3_bind_null(statement, 2)
          }
          sqlite3_bind_text(statement, 3, node.url, -1, Self.transient)
          sqlite3_bind_text(statement, 4, node.title, -1, Self.transient)
          sqlite3_bind_double(statement, 5, node.x)
          sqlite3_bind_double(statement, 6, node.y)
          sqlite3_bind_int(statement, 7, node.isArchived ? 1 : 0)
          sqlite3_bind_double(statement, 8, node.updatedAt)
        }
      }
      for edge in graph.edges {
        try run("INSERT INTO canvas_edges(from_id, to_id, kind, run_id) VALUES (?1, ?2, ?3, ?4)") {
          statement in
          sqlite3_bind_text(statement, 1, edge.from, -1, Self.transient)
          sqlite3_bind_text(statement, 2, edge.to, -1, Self.transient)
          sqlite3_bind_text(statement, 3, edge.kind.rawValue, -1, Self.transient)
          sqlite3_bind_text(statement, 4, edge.runId ?? "", -1, Self.transient)
        }
      }
      let meta = [
        ("title", graph.title), ("viewport.cx", "\(graph.viewport.cx)"),
        ("viewport.cy", "\(graph.viewport.cy)"), ("viewport.zoom", "\(graph.viewport.zoom)"),
      ]
      for (key, value) in meta {
        try run("INSERT INTO canvas_meta(key, value) VALUES (?1, ?2)") { statement in
          sqlite3_bind_text(statement, 1, key, -1, Self.transient)
          sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        }
      }
      try exec(db, "COMMIT")
    } catch {
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      throw error
    }
  }

  /// Read once at launch, before anything else uses the connection (like `abandonPending`).
  public nonisolated func loadCanvas() -> PageGraph {
    let nodes = Self.select(
      db, "SELECT id, url, title, x, y, updated_at FROM canvas_nodes ORDER BY rowid"
    ) {
      PageNode(
        id: Self.text($0, 0), tabId: nil, url: Self.text($0, 1), title: Self.text($0, 2),
        x: sqlite3_column_double($0, 3), y: sqlite3_column_double($0, 4),
        updatedAt: sqlite3_column_double($0, 5))
    }
    let edges = Self.select(
      db, "SELECT from_id, to_id, kind, run_id FROM canvas_edges ORDER BY rowid"
    ) {
      statement -> PageEdge? in
      guard let kind = EdgeKind(rawValue: Self.text(statement, 2)) else { return nil }
      let run = Self.text(statement, 3)
      return PageEdge(
        from: Self.text(statement, 0), to: Self.text(statement, 1), kind: kind,
        runId: run.isEmpty ? nil : run)
    }
    var meta: [String: String] = [:]
    for pair in Self.select(
      db, "SELECT key, value FROM canvas_meta", { (Self.text($0, 0), Self.text($0, 1)) })
    {
      meta[pair.0] = pair.1
    }
    let number = { (key: String) in meta[key].flatMap(Double.init) }
    let viewport = number("viewport.cx").flatMap { cx in
      number("viewport.cy").flatMap { cy in
        number("viewport.zoom").map { Viewport(cx: cx, cy: cy, zoom: $0) }
      }
    }
    return PageGraph(
      restoring: nodes, edges: edges.compactMap { $0 }, title: meta["title"] ?? "",
      viewport: viewport)
  }

  private func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw Failure(message: String(cString: sqlite3_errmsg(db)))
    }
  }

  private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }

  private static func select<T>(_ db: OpaquePointer, _ sql: String, _ read: (OpaquePointer?) -> T)
    -> [T]
  {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var out: [T] = []
    while sqlite3_step(statement) == SQLITE_ROW { out.append(read(statement)) }
    return out
  }
}
