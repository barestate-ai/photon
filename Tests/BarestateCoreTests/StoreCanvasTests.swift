import BarestateCore
import Foundation
import SQLite3
import Testing

struct StoreCanvasTests {
  private func withStore(_ body: (Store, String) async throws -> Void) async throws {
    let path = NSTemporaryDirectory() + "bs-canvas-\(UUID().uuidString).sqlite"
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    try await body(try Store(path: path), path)
  }

  private func graph() -> PageGraph {
    var graph = PageGraph()
    graph.observe(tab: "t1", url: "https://a.test/", title: "A", origin: .none, now: 1)
    let a = graph.nodeId(forTab: "t1")!
    graph.observe(
      tab: "t2", url: "https://b.test/", title: "B 'quoted'",
      origin: .from(node: a, kind: .openedFrom),
      now: 2)
    graph.observe(tab: "t3", url: "https://c.test/", title: "", origin: .none, now: 3)
    graph.museUsed(run: "r1", ownerTab: "t1", usedTab: "t3")
    graph.close(tab: "t3", now: 4)
    graph.setTitle("Trip planning")
    graph.viewport = Viewport(cx: 12.345678901234, cy: -0.5, zoom: 0.73)
    return graph
  }

  private func rows(_ path: String, _ sql: String) -> [String] {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    var out: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      out.append(String(cString: sqlite3_column_text(statement, 0)))
    }
    return out
  }

  @Test func theTablesHoldLiveAndArchivedNodesEdgesAndMeta() async throws {
    try await withStore { store, path in
      try await store.saveCanvas(graph())
      #expect(
        rows(path, "SELECT id || ':' || ifnull(tab_id,'-') || ':' || archived FROM canvas_nodes")
          == ["n1:t1:0", "n2:t2:0", "n3:-:1"])
      #expect(
        rows(
          path, "SELECT from_id || '>' || to_id || ':' || kind || ':' || run_id FROM canvas_edges")
          == ["n1>n2:openedFrom:", "n1>n3:museUsed:r1"])
      #expect(rows(path, "SELECT value FROM canvas_meta WHERE key = 'title'") == ["Trip planning"])
    }
  }

  @Test func loadingRestoresEveryNodeArchivedWithPositionsEdgesTitleAndViewport() async throws {
    try await withStore { store, _ in
      let saved = graph()
      try await store.saveCanvas(saved)
      let loaded = store.loadCanvas()
      #expect(loaded.nodes.allSatisfy { $0.isArchived })
      #expect(loaded.nodes.map { [$0.x, $0.y] } == saved.nodes.map { [$0.x, $0.y] })
      #expect(loaded.nodes.map(\.url) == saved.nodes.map(\.url))
      #expect(loaded.nodes.map(\.title) == saved.nodes.map(\.title))
      #expect(loaded.edges == saved.edges)
      #expect(loaded.title == "Trip planning")
      #expect(loaded.viewport == saved.viewport)
    }
  }

  @Test func aSavedDefaultViewportIsStillARestoredCamera() async throws {
    try await withStore { store, _ in
      var saved = graph()
      saved.viewport = Viewport()
      try await store.saveCanvas(saved)
      let loaded = store.loadCanvas()
      #expect(loaded.viewport == Viewport())
      #expect(loaded.hasRestoredCamera)
    }
  }

  @Test func noPagesOrNoSavedViewportMeansNoRestoredCamera() async throws {
    try await withStore { store, path in
      #expect(!store.loadCanvas().hasRestoredCamera)
      try await store.saveCanvas(PageGraph())
      #expect(!store.loadCanvas().hasRestoredCamera)
      try await store.saveCanvas(graph())
      execute(path, "DELETE FROM canvas_meta WHERE key LIKE 'viewport.%'")
      let loaded = store.loadCanvas()
      #expect(loaded.viewport == Viewport())
      #expect(!loaded.hasRestoredCamera)
    }
  }

  private func execute(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, sql, nil, nil, nil)
  }

  @Test func savingAgainReplacesWhatWasThereAndAFreshStoreLoadsAnEmptyGraph() async throws {
    try await withStore { store, path in
      #expect(store.loadCanvas() == PageGraph())
      try await store.saveCanvas(graph())
      var smaller = PageGraph()
      smaller.observe(tab: "t9", url: "https://z.test/", title: "Z", origin: .none, now: 9)
      try await store.saveCanvas(smaller)
      #expect(rows(path, "SELECT count(*) FROM canvas_nodes") == ["1"])
      #expect(rows(path, "SELECT count(*) FROM canvas_edges") == ["0"])
      #expect(store.loadCanvas().title == PageGraph.defaultTitle)
    }
  }
}
