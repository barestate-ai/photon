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
}
