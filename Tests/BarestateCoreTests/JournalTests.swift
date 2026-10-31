import BarestateCore
import Foundation
import SQLite3
import Testing

struct JournalTests {
  private func makeStore() throws -> (Store, String) {
    let path = NSTemporaryDirectory() + "bs-journal-\(UUID().uuidString).sqlite"
    return (try Store(path: path), path)
  }

  private func remove(_ path: String) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }

  private func newAction(_ clientActionId: String = "a1", session: String = "s1") -> NewAction {
    NewAction(
      sessionId: session, clientActionId: clientActionId, tabId: "t1", epoch: 4,
      observationId: "t1-o1", kind: "click", target: "8", textHash: nil)
  }

  @Test func theRowIsPendingWithItsContextAsSoonAsItIsRecorded() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (row, created) = try await store.record(newAction())
    #expect(created)
    #expect(row.state == .pending)
    #expect(row.sessionId == "s1" && row.clientActionId == "a1")
    #expect(row.tabId == "t1" && row.epoch == 4 && row.observationId == "t1-o1")
    #expect(row.kind == "click" && row.target == "8")
    #expect(await store.action(id: row.id) == row)
  }

  @Test func recordingTheSamePairAgainReturnsTheOriginalRowUnchanged() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (first, _) = try await store.record(newAction())
    let settled = try await store.settle(
      id: first.id, state: .confirmed, reason: nil, domVerdict: "ok")
    let (again, created) = try await store.record(newAction())
    #expect(!created)
    #expect(again == settled)
    #expect(again.id == first.id)
  }

  @Test func theSamePairInAnotherSessionOrADifferentIdIsANewRow() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (first, _) = try await store.record(newAction())
    let (otherId, createdId) = try await store.record(newAction("a2"))
    let (otherSession, createdSession) = try await store.record(newAction(session: "s2"))
    #expect(createdId && createdSession)
    #expect(Set([first.id, otherId.id, otherSession.id]).count == 3)
  }

  @Test func aSettledRowNeverChangesAgain() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (row, _) = try await store.record(newAction())
    _ = try await store.settle(
      id: row.id, state: .cancelled, reason: "stale: epoch", domVerdict: nil)
    let late = try await store.settle(id: row.id, state: .confirmed, reason: nil, domVerdict: "ok")
    #expect(late.state == .cancelled)
    #expect(late.reason == "stale: epoch")
  }

  @Test func rowsLeftPendingByALostRunBecomeOutcomeUnknownWhenTheStoreReopens() async throws {
    let path = NSTemporaryDirectory() + "bs-journal-\(UUID().uuidString).sqlite"
    defer { remove(path) }
    let first = try Store(path: path)
    let (pending, _) = try await first.record(newAction())
    let (done, _) = try await first.record(newAction("a2"))
    _ = try await first.settle(id: done.id, state: .confirmed, reason: nil, domVerdict: "ok")

    let reopened = try Store(path: path)
    let (held, _) = try await first.record(newAction("a3"))
    _ = try await first.quote(id: held.id, tokenHash: "h", sensitive: true, reason: nil)
    #expect(try reopened.reconcile() == 2)
    let after = try #require(await reopened.action(id: pending.id))
    #expect(after.state == .outcomeUnknown)
    #expect(after.reason?.hasPrefix("app-restarted") == true)
    #expect(await reopened.action(id: done.id)?.state == .confirmed)
    let quoted = try #require(await reopened.action(id: held.id))
    #expect(quoted.state == .cancelled && quoted.approvalTokenHash == "h")
    #expect(try reopened.reconcile() == 0)
  }

  @Test func aQuotedRowIsApprovedOnceAndKeepsItsTokenAndVerdicts() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (row, _) = try await store.record(newAction())
    let quoted = try await store.quote(id: row.id, tokenHash: "abc", sensitive: true, reason: "r")
    #expect(quoted.state == .quoted && quoted.sensitive && quoted.approvalTokenHash == "abc")
    #expect(quoted.json["sensitive"] == true && quoted.json["approvalTokenHash"] == nil)
    #expect(try await store.approve(id: row.id))
    #expect(try await store.approve(id: row.id) == false)
    let done = try await store.settle(
      id: row.id, state: .confirmed, reason: nil, domVerdict: "state-changed",
      modelVerdict: "success: moved")
    #expect(done.modelVerdict == "success: moved" && done.approvalTokenHash == "abc")
    #expect(try await store.approve(id: row.id) == false)
  }

  @Test func aResolvedInstructionRecordsItsTargetAndRungUntilTheRowEnds() async throws {
    let (store, path) = try makeStore()
    defer { remove(path) }
    let (row, _) = try await store.record(newAction())
    #expect(row.rung == nil)
    try await store.resolve(id: row.id, target: "42", rung: "atom")
    let resolved = try #require(await store.action(id: row.id))
    #expect(resolved.target == "42" && resolved.rung == "atom")
    #expect(resolved.json["rung"] == "atom")
    _ = try await store.settle(id: row.id, state: .confirmed, reason: nil, domVerdict: "ok")
    try await store.resolve(id: row.id, target: "7", rung: "dom")
    #expect(await store.action(id: row.id)?.rung == "atom")
  }

  @Test func aDataDirectoryFromBeforeRungsGainsTheColumnWhenReopened() async throws {
    let path = NSTemporaryDirectory() + "bs-journal-\(UUID().uuidString).sqlite"
    defer { remove(path) }
    var handle: OpaquePointer?
    #expect(sqlite3_open(path, &handle) == SQLITE_OK)
    let old = """
      CREATE TABLE actions(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL,
        client_action_id TEXT NOT NULL, tab_id TEXT, epoch INTEGER, observation_id TEXT, kind TEXT,
        target TEXT, text_hash TEXT, state TEXT NOT NULL, sensitive INTEGER, approval_token_hash TEXT,
        dom_verdict TEXT, model_verdict TEXT, reason TEXT, created_at REAL, updated_at REAL,
        UNIQUE(session_id, client_action_id));
      """
    #expect(sqlite3_exec(handle, old, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let store = try Store(path: path)
    let (row, _) = try await store.record(
      NewAction(
        sessionId: "s", clientActionId: "c", tabId: nil, epoch: nil, observationId: "o",
        kind: "click", target: "1", textHash: nil, rung: "ref"))
    #expect(row.rung == "ref")
  }
}
