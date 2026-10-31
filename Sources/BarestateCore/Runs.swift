import Foundation

public enum RunOrigin: String, Sendable {
  case mac, phone
}

public enum RunState: String, Sendable {
  case pending, running
  case waitingApproval = "waiting-approval"
  case stopped, completed, failed
}

extension RunState {
  /// A task that has not ended.
  public var isInProgress: Bool { self == .pending || self == .running || self == .waitingApproval }

  /// The word after "Muse ·" on the page the task belongs to.
  public var statusLabel: String {
    switch self {
    case .pending: "connecting"
    case .running: "working"
    case .waitingApproval: "waiting for approval"
    case .stopped: "stopped"
    case .completed: "completed"
    case .failed: "failed"
    }
  }
}

/// One observe, extract or act call of a run. An act's state is its journal row's.
public struct RunStep: Sendable, Equatable {
  public let id: Int
  public let kind: String
  /// Plain words for the activity view; never typed text or page content.
  public let text: String
  public let tabId: String?
  public var state: String
  public var reason: String?
  public var actionId: Int?
  public let startedAt: Double
  public var endedAt: Double?
}

public struct Run: Sendable, Equatable {
  public let id: String
  public let origin: RunOrigin
  public let prompt: String
  /// The page the run belongs to; a run that opens its own page owns the first one.
  public var ownerTabId: String?
  public var state: RunState
  public var reason: String?
  public var costUSD = 0.0
  public var steps: [RunStep] = []
}

/// Every run this process has started, oldest first.
public struct RunBook: Sendable {
  public private(set) var runs: [Run] = []

  public init() {}

  /// A blank prompt is not a task.
  public mutating func start(prompt: String, origin: RunOrigin, ownerTabId: String?) -> Run? {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let run = Run(
      id: "r\(runs.count + 1)", origin: origin, prompt: text, ownerTabId: ownerTabId,
      state: .pending)
    runs.append(run)
    return run
  }

  /// pending → running ⇄ waiting-approval → stopped | failed | completed. An ended run stays
  /// ended with its first reason.
  @discardableResult
  public mutating func move(_ id: String, to state: RunState, reason: String? = nil) -> Bool {
    guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].state != state else {
      return false
    }
    let from = runs[index].state
    switch (from, state) {
    case (.pending, .running), (.running, .waitingApproval), (.waitingApproval, .running): break
    case (_, .stopped), (_, .failed), (_, .completed): guard from.isInProgress else { return false }
    default: return false
    }
    runs[index].state = state
    runs[index].reason = reason
    return true
  }

  public mutating func setOwner(_ id: String, tab: String) {
    guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].ownerTabId == nil else {
      return
    }
    runs[index].ownerTabId = tab
  }

  public mutating func setCost(run id: String, usd: Double) {
    guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
    runs[index].costUSD = usd
  }

  /// Returns the new step's id, or nil for an unknown run.
  public mutating func addStep(
    run id: String, kind: String, text: String, tabId: String?, now: Double
  )
    -> Int?
  {
    guard let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
    let step = RunStep(
      id: runs[index].steps.count + 1, kind: kind, text: text, tabId: tabId, state: "working",
      startedAt: now)
    runs[index].steps.append(step)
    return step.id
  }

  public mutating func finishStep(
    run id: String, step: Int, state: String, reason: String?, actionId: Int?, now: Double
  ) {
    guard let index = runs.firstIndex(where: { $0.id == id }),
      let at = runs[index].steps.firstIndex(where: { $0.id == step })
    else { return }
    runs[index].steps[at].state = state
    runs[index].steps[at].reason = reason
    runs[index].steps[at].actionId = actionId
    runs[index].steps[at].endedAt = now
  }
}

/// How a run ends once the loop stops (architecture §5.10): completed only when the model ended
/// the task and every write the run made is confirmed.
public enum RunOutcome {
  public static func conclude(
    modelEnded: Bool, writes: [(state: ActionState, reason: String?)]
  ) -> (state: RunState, reason: String?) {
    if let bad = writes.first(where: { $0.state != .confirmed }) {
      let why = bad.reason.map { ": \($0)" } ?? ""
      return (.failed, "a write ended \(bad.state.rawValue)\(why)")
    }
    return modelEnded ? (.completed, nil) : (.failed, "the model did not finish the task")
  }

  /// What a run's end may say in the log. Reasons can quote a verifier's or provider's free text,
  /// which can quote the page, so only these words go out.
  public static func logCategory(_ reason: String?) -> String {
    guard let reason else { return "-" }
    let known = ["run-cap", "turn-limit", "taken-over", "stopped", "disconnected"]
    if known.contains(reason) { return reason }
    if reason == AgentLoop.incompleteTurn { return "model-incomplete" }
    return reason.hasPrefix("a write ended") ? "write-not-confirmed" : "other"
  }
}

/// The per-run cap is $3 (`per_run_cap_usd` in the ledger). A run stops at $2.99, so no call
/// starts that the run could not pay for in whole (VAL-MODEL-005).
public enum RunCap {
  public static let stopAtUSD = 2.99

  public static func exceeded(_ costUSD: Double) -> Bool { costUSD >= stopAtUSD }
}
