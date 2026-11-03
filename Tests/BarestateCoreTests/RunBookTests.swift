import BarestateCore
import Testing

struct RunBookTests {
  @Test func startRecordsAPendingRunWithItsOwnerTab() {
    var book = RunBook()
    let run = book.start(prompt: " Find a hotel ", origin: .mac, ownerTabId: "t3")
    #expect(run?.id == "r1")
    #expect(run?.prompt == "Find a hotel")
    #expect(run?.state == .pending)
    #expect(run?.ownerTabId == "t3")
    #expect(run?.origin == .mac)
    #expect(run?.costUSD == 0)
    #expect(book.runs.count == 1)
  }

  @Test func idsCountUpAndABlankPromptIsNotARun() {
    var book = RunBook()
    #expect(book.start(prompt: "   ", origin: .mac, ownerTabId: nil) == nil)
    #expect(book.runs.isEmpty)
    _ = book.start(prompt: "a", origin: .mac, ownerTabId: nil)
    let second = book.start(prompt: "b", origin: .phone, ownerTabId: nil)
    #expect(second?.id == "r2")
    #expect(book.runs.map(\.prompt) == ["a", "b"])
  }

  @Test func stateNamesMatchTheSocketSpelling() {
    #expect(RunState.waitingApproval.rawValue == "waiting-approval")
  }

  @Test func theStatusLabelNamesWhatTheTaskIsDoingUntilItEnds() {
    #expect(RunState.pending.statusLabel == "connecting")
    #expect(RunState.running.statusLabel == "working")
    #expect(RunState.waitingApproval.statusLabel == "waiting for approval")
    #expect(RunState.stopped.statusLabel == "stopped")
    #expect(RunState.failed.statusLabel == "failed")
    #expect(RunState.completed.statusLabel == "completed")
    #expect([RunState.pending, .running, .waitingApproval].allSatisfy { $0.isInProgress })
    #expect([RunState.stopped, .completed, .failed].allSatisfy { !$0.isInProgress })
  }

  @Test func aNewTaskOnAPageLeavesTheTasksStillWorkingOnItBehind() {
    var book = RunBook()
    let first = book.start(prompt: "a", origin: .mac, ownerTabId: "t1")!
    let waiting = book.start(prompt: "b", origin: .mac, ownerTabId: "t1")!
    _ = book.move(waiting.id, to: .running)
    _ = book.move(waiting.id, to: .waitingApproval)
    let done = book.start(prompt: "c", origin: .mac, ownerTabId: "t1")!
    _ = book.move(done.id, to: .stopped)
    let elsewhere = book.start(prompt: "d", origin: .mac, ownerTabId: "t2")!
    let next = book.start(prompt: "e", origin: .mac, ownerTabId: "t1")!
    #expect(book.superseded(by: next).map(\.id) == [first.id, waiting.id])
    #expect(book.superseded(by: elsewhere).isEmpty)
  }

  @Test func aTaskWithNoPageSupersedesNothing() {
    var book = RunBook()
    _ = book.start(prompt: "a", origin: .phone, ownerTabId: nil)
    let next = book.start(prompt: "b", origin: .phone, ownerTabId: nil)!
    #expect(book.superseded(by: next).isEmpty)
  }
}
