import BarestateCore
import Testing

struct RunStateTests {
  private func started(owner: String? = "t1") -> (RunBook, String) {
    var book = RunBook()
    let run = book.start(prompt: "go", origin: .mac, ownerTabId: owner)!
    return (book, run.id)
  }

  @Test func aRunMovesPendingToRunningAndBackAndForthWithApprovals() {
    var (book, id) = started()
    let moved1 = book.move(id, to: .waitingApproval)  // not before it runs
    #expect(!moved1)
    let moved2 = book.move(id, to: .running)
    #expect(moved2)
    let moved3 = book.move(id, to: .waitingApproval)
    #expect(moved3)
    let moved4 = book.move(id, to: .running)
    #expect(moved4)
    #expect(book.runs[0].state == .running)
  }

  @Test func anEndedRunStaysEndedAndKeepsItsFirstReason() {
    var (book, id) = started()
    let moved5 = book.move(id, to: .running)
    #expect(moved5)
    let moved6 = book.move(id, to: .stopped, reason: "taken-over")
    #expect(moved6)
    let moved7 = book.move(id, to: .failed, reason: "run-cap")
    #expect(!moved7)
    let moved8 = book.move(id, to: .completed)
    #expect(!moved8)
    let moved9 = book.move(id, to: .running)
    #expect(!moved9)
    #expect(book.runs[0].state == .stopped)
    #expect(book.runs[0].reason == "taken-over")
  }

  @Test func aRunCanEndBeforeItEverRan() {
    var (book, id) = started()
    let moved10 = book.move(id, to: .failed, reason: "no-key")
    #expect(moved10)
    #expect(book.runs[0].state == .failed)
  }

  @Test func eachCallIsOneStepThatTakesTheStateOfItsJournalRow() {
    var (book, id) = started()
    let step = book.addStep(run: id, kind: "act", text: "Click \"Save\"", tabId: "t1", now: 5)
    #expect(step == 1)
    #expect(book.runs[0].steps[0].state == "working")
    book.finishStep(run: id, step: 1, state: "confirmed", reason: nil, actionId: 7, now: 6)
    let done = book.runs[0].steps[0]
    #expect((done.state, done.actionId, done.startedAt, done.endedAt) == ("confirmed", 7, 5, 6))
    #expect(book.addStep(run: id, kind: "observe", text: "Look", tabId: nil, now: 7) == 2)
    #expect(book.addStep(run: "nope", kind: "observe", text: "Look", tabId: nil, now: 7) == nil)
  }

  @Test func costOnlyGrowsFromTheLedgerFigure() {
    var (book, id) = started()
    book.setCost(run: id, usd: 1.5)
    #expect(book.runs[0].costUSD == 1.5)
  }
}

struct RunOutcomeTests {
  private typealias Write = (state: ActionState, reason: String?)

  @Test func everyWriteConfirmedAndTheModelEndingCompletes() {
    let writes: [Write] = [(.confirmed, nil), (.confirmed, nil)]
    let end = RunOutcome.conclude(modelEnded: true, writes: writes)
    #expect(end.state == .completed && end.reason == nil)
  }

  @Test func aReadOnlyRunWhoseModelStoppedCompletes() {
    #expect(RunOutcome.conclude(modelEnded: true, writes: []).state == .completed)
  }

  @Test func anyWriteThatIsNotConfirmedFailsTheRunAndNamesIt() {
    for (state, reason) in [
      (ActionState.outcomeUnknown, "model unavailable: timeout"), (.failed, "read-back mismatch"),
      (.cancelled, "denied"), (.pending, nil), (.quoted, nil),
    ] {
      let end = RunOutcome.conclude(
        modelEnded: true, writes: [(.confirmed, nil), (state, reason)])
      #expect(end.state == .failed)
      #expect(end.reason?.contains(state.rawValue) == true)
      if let reason { #expect(end.reason?.contains(reason) == true) }
    }
  }

  @Test func aModelThatDidNotEndTheTaskFailsEvenWithConfirmedWrites() {
    let end = RunOutcome.conclude(modelEnded: false, writes: [(.confirmed, nil)])
    #expect(end.state == .failed && end.reason != nil)
  }

  @Test func theLogNamesACategoryNeverTheReason() {
    let secret = "SENTINEL-page-text"
    let reasons = [
      "a write ended outcome-unknown: \(secret)", "model rejected the request (400): \(secret)",
      "\(secret)",
    ]
    for reason in reasons { #expect(!RunOutcome.logCategory(reason).contains(secret)) }
    #expect(RunOutcome.logCategory(nil) == "-")
    #expect(RunOutcome.logCategory("a write ended failed: \(secret)") == "write-not-confirmed")
    #expect(RunOutcome.logCategory("model response incomplete") == "model-incomplete")
    for fixed in ["run-cap", "turn-limit", "taken-over", "stopped", "superseded"] {
      #expect(RunOutcome.logCategory(fixed) == fixed)
    }
  }

  @Test func aRunStopsAtTwoNinetyNineOfItsThreeDollars() {
    #expect(RunCap.exceeded(2.98) == false)
    #expect(RunCap.exceeded(2.99))
    #expect(RunCap.exceeded(3.4))
  }
}
