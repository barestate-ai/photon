import Foundation

extension Run {
  /// Why a failed run failed, as a sentence; nil in any other state.
  public var failure: String? { state == .failed ? RunOutcome.plainReason(reason) : nil }

  /// The words a page or node carries while this run owns it. A failed run adds a few words on
  /// why, short enough for the overview card; `failure` is the whole sentence.
  public var museLabel: String {
    let why = state == .failed ? RunOutcome.shortReason(reason) : nil
    return "Muse · \(state.statusLabel)" + (why.map { " · \($0)" } ?? "")
  }
}

extension RunBook {
  /// The runs that belong to a page, oldest first, whatever state they are in.
  public func runs(ownedBy tab: String?) -> [Run] {
    guard let tab else { return [] }
    return runs.filter { $0.ownerTabId == tab }
  }
}

/// What the run activity view shows for one run: a line per step the run took (the journal row of
/// an act carries its own state and reason), then what is waiting for a person.
public struct RunActivity: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let id: Int
    public let text: String
    /// "<page title> · <state> · <reason>", with the parts that exist.
    public let detail: String
  }

  public let runId: String
  public let prompt: String
  public let status: String
  public let reason: String?
  /// What follows the status: the sentence for a failure, else the recorded reason.
  public let because: String?
  /// The model's closing reply, when it gave one.
  public let answer: String?
  public let canStop: Bool
  public let entries: [Entry]
  public let waiting: [String]

  /// The default subject: the run in progress, else the newest one.
  public static func subject(in runs: [Run]) -> Run? {
    runs.last { $0.state.isInProgress } ?? runs.last
  }

  /// `pages` names the tabs of the steps by their titles; a page that has gone is left out.
  public init(_ run: Run, pages: [String: String] = [:], waiting: [String] = []) {
    runId = run.id
    prompt = run.prompt
    status = run.state.statusLabel
    reason = run.reason
    because = run.failure ?? run.reason
    answer = run.answer
    canStop = run.state.isInProgress
    entries = run.steps.map { step in
      let parts = [step.tabId.flatMap { pages[$0] }, step.state, step.reason]
        .compactMap { $0 }.filter { !$0.isEmpty }
      return Entry(id: step.id, text: step.text, detail: parts.joined(separator: " · "))
    }
    self.waiting = waiting
  }
}
