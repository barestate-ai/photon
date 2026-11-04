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
    #expect(RunOutcome.logCategory(RunOutcome.declined) == "model-declined")
    for fixed in ["run-cap", "turn-limit", "taken-over", "stopped"] {
      #expect(RunOutcome.logCategory(fixed) == fixed)
    }
  }

  @Test func aStructuredRefusalFailsAReadOnlyRunButNotBeforeAFailedWrite() {
    let end = RunOutcome.conclude(modelEnded: true, writes: [(.confirmed, nil)], refused: true)
    #expect(end.state == .failed && end.reason == RunOutcome.declined)
    let worse = RunOutcome.conclude(modelEnded: true, writes: [(.failed, "denied")], refused: true)
    #expect(worse.reason?.hasPrefix("a write ended failed") == true)
    #expect(RunOutcome.conclude(modelEnded: true, writes: [], refused: false).state == .completed)
  }

  @Test func everyReasonARunCanFailWithGetsItsOwnSentenceAndAShortTag() {
    let general = RunOutcome.plainReason(nil)
    let reasons: [String?] = [
      "run-cap", "turn-limit", AgentLoop.incompleteTurn, RunOutcome.declined,
      "a write ended outcome-unknown: denied", "a write ended cancelled: denied",
      "a write ended cancelled: stale: epoch", "a write ended failed: needs-human",
      "\(ModelError.noKey)", "\(ModelError.capReached(total: 20))", "\(ModelError.unreachable)",
      "\(ModelError.timeout)", "\(ModelError.server(status: 503))",
      "\(ModelError.rejected(status: 401, message: "x"))",
      "\(ModelError.rejected(status: 402, message: "x"))",
      "\(ModelError.rejected(status: 403, message: "x"))",
      "\(ModelError.rejected(status: 418, message: "x"))", "\(ModelError.malformed("x"))",
      "\(ModelError.refused("run-cap"))",
    ]
    for reason in reasons {
      let sentence = RunOutcome.plainReason(reason)
      #expect(sentence != general, "\(reason ?? "nil")")
      #expect(sentence.hasSuffix(".") && sentence.count < 70, "\(sentence)")
      // The overview card is 206 pt wide and draws "Muse · failed · <tag>" in one line: a tag of
      // 16 characters or fewer measured 175 pt at most with the bundled Manrope at 12 pt.
      let tag = RunOutcome.shortReason(reason)
      #expect((tag?.count ?? 99) <= 16, "\(reason ?? "nil")")
    }
    #expect(RunOutcome.plainReason("run-cap") == "The task reached its spending limit.")
    #expect(RunOutcome.shortReason("run-cap") == "spending limit")
    #expect(
      RunOutcome.plainReason("turn-limit") == "The task took too many steps without finishing.")
    #expect(RunOutcome.plainReason("\(ModelError.timeout)") == "The model took too long to answer.")
    #expect(RunOutcome.shortReason(nil) == nil && RunOutcome.shortReason("needs-human") == nil)
  }

  @Test func theKeyAndCreditSentencesFitBothTheHostedMuseAndAKeyOfTheirOwn() {
    // What the Barestate Muse worker answers (server/barestate-api/worker.mjs): no key, no credit.
    let revoked = "\(ModelError.rejected(status: 401, message: "Unknown or revoked device token."))"
    let daily = "Barestate Muse daily limit reached for this device. Try again tomorrow."
    let limit = "\(ModelError.rejected(status: 402, message: daily))"
    #expect(
      RunOutcome.plainReason(revoked)
        == "The model did not accept Photon's access. Check Model in Settings.")
    #expect(
      RunOutcome.plainReason(limit)
        == "Usage limit reached. Try again later, or check Model in Settings.")
    #expect(RunOutcome.shortReason(limit) == "usage limit")
    #expect(RunOutcome.plainReason(limit) != RunOutcome.plainReason(revoked))
    for sentence in [RunOutcome.plainReason(revoked), RunOutcome.plainReason(limit)] {
      #expect(!sentence.localizedCaseInsensitiveContains("API key"))
      #expect(!sentence.localizedCaseInsensitiveContains("credit"))
    }
  }

  @Test func aWriteThatEndedUnconfirmedSaysWhichWayItEnded() {
    func sentence(_ state: ActionState, _ why: String?) -> String? {
      let end = RunOutcome.conclude(modelEnded: true, writes: [(state, why)])
      return end.state == .failed ? RunOutcome.plainReason(end.reason) : nil
    }
    #expect(
      sentence(.cancelled, "denied") == "A change was not made: it was denied, or the page changed."
    )
    #expect(sentence(.cancelled, "stale: epoch") == sentence(.cancelled, "denied"))
    #expect(sentence(.failed, "needs-human") == "A change did not go through.")
    #expect(sentence(.outcomeUnknown, "denied") == "The last change could not be confirmed.")
    #expect(sentence(.pending, nil) == "The last change could not be confirmed.")
  }

  @Test func aReasonWeHaveNoSentenceForGetsTheGeneralOneAndNeverQuotesTheOriginal() {
    let secret = "SENTINEL-page-text"
    let general = RunOutcome.plainReason(nil)
    #expect(RunOutcome.plainReason("the model did not finish the task") == general)
    #expect(RunOutcome.plainReason("\(ModelError.ledger(secret))") == general)
    let sentences = [
      RunOutcome.plainReason("a write ended failed: \(secret)"),
      RunOutcome.plainReason("\(ModelError.rejected(status: 400, message: secret))"),
      RunOutcome.plainReason("\(ModelError.malformed(secret))"), RunOutcome.plainReason(secret),
    ]
    for sentence in sentences { #expect(!sentence.contains(secret)) }
  }

  @Test func aRunStopsAtTwoNinetyNineOfItsThreeDollars() {
    #expect(RunCap.exceeded(2.98) == false)
    #expect(RunCap.exceeded(2.99))
    #expect(RunCap.exceeded(3.4))
  }
}
