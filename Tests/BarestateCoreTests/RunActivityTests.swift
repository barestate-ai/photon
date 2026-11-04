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
    #expect(book.runs(ownedBy: "t1").last?.museLabel == "Muse · failed · no key")
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

  @Test func onlyAFailedRunPutsItsReasonInTheLabel() {
    var book = book()
    book.move("r1", to: .running)
    #expect(book.runs[0].museLabel == "Muse · working")
    book.move("r1", to: .stopped, reason: "taken-over")
    #expect(book.runs[0].museLabel == "Muse · stopped")
    book.move("r2", to: .completed, answer: "Kyoto is older.")
    #expect(book.runs[1].museLabel == "Muse · completed")
    #expect(book.runs[1].failure == nil)
    var failed = RunBook()
    _ = failed.start(prompt: "go", origin: .mac, ownerTabId: nil)
    failed.move("r1", to: .running)
    failed.move("r1", to: .failed, reason: "turn-limit")
    #expect(failed.runs[0].museLabel == "Muse · failed · too many steps")
    #expect(failed.runs[0].failure == RunOutcome.plainReason("turn-limit"))
    var unknown = RunBook()
    _ = unknown.start(prompt: "go", origin: .mac, ownerTabId: nil)
    unknown.move("r1", to: .running)
    unknown.move("r1", to: .failed, reason: "needs-human")
    #expect(unknown.runs[0].museLabel == "Muse · failed")
  }

  @Test func theActivityCarriesTheAnswerAndTheSentenceThatFollowsTheStatus() {
    var book = book()
    book.move("r1", to: .running)
    book.move("r1", to: .completed, answer: "Kyoto is older; Tokyo is bigger.")
    book.move("r2", to: .running)
    book.move("r2", to: .failed, reason: "model timed out")
    let done = RunActivity(book.runs[0])
    #expect(done.answer == "Kyoto is older; Tokyo is bigger.")
    #expect(done.because == nil)
    let failed = RunActivity(book.runs[1])
    #expect(failed.answer == nil)
    #expect(failed.because == "The model took too long to answer.")
    #expect(failed.reason == "model timed out")
  }

  @Test func aStoppedRunKeepsItsRecordedReasonAfterTheStatus() {
    var book = book()
    book.move("r1", to: .running)
    book.move("r1", to: .stopped, reason: "taken-over")
    #expect(RunActivity(book.runs[0]).because == "taken-over")
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
