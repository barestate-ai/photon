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

  @Test func theAnswerIsKeptOnTheMoveThatEndsTheRunAndNotOverwrittenAfterwards() {
    var book = RunBook()
    let id = book.start(prompt: "compare Kyoto and Tokyo", origin: .mac, ownerTabId: nil)!.id
    #expect(book.runs[0].answer == nil && !book.runs[0].refused)
    book.move(id, to: .running)
    #expect(book.runs[0].answer == nil)
    book.move(id, to: .completed, answer: "Kyoto is older.", refused: false)
    book.move(id, to: .stopped, reason: "stopped", answer: "late", refused: true)
    #expect(book.runs[0].state == .completed)
    #expect(book.runs[0].answer == "Kyoto is older." && !book.runs[0].refused)
    var other = RunBook()
    let said = other.start(prompt: "go", origin: .mac, ownerTabId: nil)!.id
    other.move(said, to: .running)
    other.move(said, to: .failed, reason: RunOutcome.declined, answer: "No.", refused: true)
    #expect(other.runs[0].answer == "No." && other.runs[0].refused)
    var unconfirmed = RunBook()
    let sent = unconfirmed.start(prompt: "go", origin: .mac, ownerTabId: nil)!.id
    unconfirmed.move(sent, to: .running)
    unconfirmed.move(sent, to: .failed, reason: "a write ended failed", answer: "Done, I sent it.")
    #expect(unconfirmed.runs[0].answer == nil)
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
