import BarestateCore
import Foundation
import Testing

struct StoreBrowsingTests {
  private func withStore(_ body: (Store) async throws -> Void) async throws {
    let path = NSTemporaryDirectory() + "bs-browsing-\(UUID().uuidString).sqlite"
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
      }
    }
    try await body(try Store(path: path))
  }

  @Test func revisitingCountsAndKeepsTheLatestTitle() async throws {
    try await withStore { store in
      try await store.recordVisit(url: "https://a.test/", title: "A", at: 10)
      try await store.recordVisit(url: "https://a.test/", title: "A two", at: 20)
      try await store.recordVisit(url: "https://a.test/", title: "", at: 30)
      let rows = await store.recentSites(limit: 5)
      #expect(rows.count == 1)
      #expect(rows[0].visits == 3)
      #expect(rows[0].title == "A two")
      #expect(rows[0].lastVisit == 30)
    }
  }

  @Test func recentSitesComeNewestFirstUpToTheLimit() async throws {
    try await withStore { store in
      for (n, name) in ["old", "mid", "new"].enumerated() {
        try await store.recordVisit(url: "https://\(name).test/", title: name, at: Double(n))
      }
      let urls = await store.recentSites(limit: 2).map(\.url)
      #expect(urls == ["https://new.test/", "https://mid.test/"])
    }
  }

  @Test func equalTimesListByAddressAndBookmarksComeNewestFirst() async throws {
    try await withStore { store in
      try await store.seed(
        history: ["b", "a", "c"].map {
          Store.HistoryRow(url: "https://\($0).test/", title: $0, visits: 1, lastVisit: 5)
        },
        bookmarks: [
          Store.BookmarkRow(url: "https://x.test/", title: "x", createdAt: 1),
          Store.BookmarkRow(url: "https://z.test/", title: "z", createdAt: 2),
          Store.BookmarkRow(url: "https://y.test/", title: "y", createdAt: 2),
        ])
      #expect(
        await store.recentSites(limit: 10).map(\.title) == ["a", "b", "c"])
      #expect(await store.allBookmarks().map(\.title) == ["y", "z", "x"])
    }
  }

  @Test func bookmarkingTwiceKeepsOneRowAndTheFirstTitle() async throws {
    try await withStore { store in
      let first = try await store.addBookmark(url: "https://b.test/", title: "B", at: 1)
      #expect(first)
      #expect(await store.rowCount(.bookmarks) == 1)
      let second = try await store.addBookmark(url: "https://b.test/", title: "Other", at: 2)
      #expect(!second)
      #expect(await store.rowCount(.bookmarks) == 1)
      #expect(await store.allBookmarks().map(\.title) == ["B"])
    }
  }
}
