import BarestateCore
import Testing

struct RunActivityTests {
  private func book() -> RunBook {
    var book = RunBook()
    _ = book.start(prompt: "Find a hotel", origin: .mac, ownerTabId: "t1")
    _ = book.start(prompt: "Compare", origin: .mac, ownerTabId: "t2")
    return book
  }

  @Test func theRunsOfAPageNameTheNewestOnesState() {
    var book = book()
    _ = book.start(prompt: "Again", origin: .mac, ownerTabId: "t1")
    book.move("r1", to: .running)
    book.move("r3", to: .failed, reason: "no model API key")
    #expect(book.runs(ownedBy: "t1").map(\.id) == ["r1", "r3"])
    #expect(book.runs(ownedBy: "t1").last?.museLabel == "Muse · failed")
    #expect(book.runs(ownedBy: "t2").last?.museLabel == "Muse · connecting")
    #expect(book.runs(ownedBy: "t9").isEmpty && book.runs(ownedBy: nil).isEmpty)
  }

  @Test func theActivityHasOneEntryPerStepWithItsStateAndReason() throws {
    var book = book()
    let added = book.addStep(run: "r1", kind: "act", text: "Click Next", tabId: "t1", now: 1)
    let first = try #require(added)
    let more = book.addStep(run: "r1", kind: "act", text: "Click Buy", tabId: "t1", now: 2)
    let second = try #require(more)
    book.finishStep(run: "r1", step: first, state: "confirmed", reason: nil, actionId: 4, now: 2)
    book.finishStep(
      run: "r1", step: second, state: "failed", reason: "needs-human", actionId: 5, now: 3)
    book.move("r1", to: .failed, reason: "a write ended failed: needs-human")
    let activity = RunActivity(book.runs[0], pages: ["t1": "Hotels"], waiting: ["Click Pay"])
    #expect(activity.entries.map(\.text) == ["Click Next", "Click Buy"])
    #expect(
      activity.entries.map(\.detail) == ["Hotels · confirmed", "Hotels · failed · needs-human"])
    #expect(activity.status == "failed")
    #expect(activity.reason == "a write ended failed: needs-human")
    #expect(activity.waiting == ["Click Pay"])
    #expect(!activity.canStop)
  }

  @Test func aRunWithoutStepsHasNoEntriesAndAnActiveOneCanStop() {
    let activity = RunActivity(book().runs[0])
    #expect(activity.entries.isEmpty)
    #expect(activity.canStop)
  }

  @Test func theSubjectIsTheRunInProgressElseTheNewest() {
    var book = book()
    #expect(RunActivity.subject(in: book.runs)?.id == "r2")
    book.move("r2", to: .stopped, reason: "stopped")
    book.move("r1", to: .running)
    #expect(RunActivity.subject(in: book.runs)?.id == "r1")
    book.move("r1", to: .completed)
    #expect(RunActivity.subject(in: book.runs)?.id == "r2")
    #expect(RunActivity.subject(in: []) == nil)
  }
}
