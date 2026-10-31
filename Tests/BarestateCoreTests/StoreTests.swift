import BarestateCore
import Foundation
import Testing

struct StoreTests {
  private func tempPath() -> String {
    NSTemporaryDirectory() + "bs-store-\(UUID().uuidString).sqlite"
  }

  @Test func createsTheJournalSchemaInWALMode() async throws {
    let path = tempPath()
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let store = try Store(path: path)
    #expect(
      await store.tableNames() == [
        "actions", "bookmarks", "canvas_edges", "canvas_meta", "canvas_nodes", "history",
      ])
    #expect(await store.journalMode() == "wal")
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test func reopeningKeepsTheSchema() async throws {
    let path = tempPath()
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    _ = try Store(path: path)
    let again = try Store(path: path)
    #expect(await again.tableNames().count == 6)
  }

  @Test func releasingTheStoreLeavesOnlyTheDatabaseFile() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    var store: Store? = try Store(path: path)
    #expect(FileManager.default.fileExists(atPath: path + "-wal"))
    store = nil
    #expect(store == nil)
    #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
  }

  // A Task suspended when the message loop ends is never resumed and keeps its Store alive, so
  // quitting cannot depend on the last reference going away.
  @Test func closingLeavesOnlyTheDatabaseFileWhileTheStoreIsStillReferenced() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try Store(path: path)
    try await store.recordVisit(url: "https://a.test/", title: "A", at: 1)
    #expect(FileManager.default.fileExists(atPath: path + "-wal"))
    await store.close()
    #expect(!FileManager.default.fileExists(atPath: path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
    await store.close()
    #expect(await store.recentSites(limit: 5).isEmpty)
    #expect(await store.rowCount(.history) == 0)
    await #expect(throws: Store.Failure.self) {
      try await store.recordVisit(url: "https://b.test/", title: "B", at: 2)
    }
    #expect(await (try Store(path: path)).rowCount(.history) == 1)
    withExtendedLifetime(store) {}
  }

  @Test func failsOnAnUnwritablePath() {
    #expect(throws: Store.Failure.self) { try Store(path: "/nonexistent-dir/x.sqlite") }
  }

  @Test func seedingTwiceEndsInTheSameState() async throws {
    let path = tempPath()
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    let store = try Store(path: path)
    let history = [Store.HistoryRow(url: "https://a.test/", title: "A", visits: 2, lastVisit: 10)]
    let bookmarks = [Store.BookmarkRow(url: "https://b.test/", title: "B", createdAt: 5)]
    try await store.seed(history: history, bookmarks: bookmarks)
    try await store.seed(history: history, bookmarks: bookmarks)
    #expect(await store.rowCount(.history) == 1)
    #expect(await store.rowCount(.bookmarks) == 1)
  }
}
