import BarestateCore
import Foundation

/// What waits for a human's Allow once or Deny (architecture §5.6): a sensitive action, held
/// `quoted`, or an agent's request for control of a page. The card on the page and the socket's
/// `approval.*` methods are two views of the same list.
@MainActor
final class Approvals {
  struct Item: Equatable {
    enum Subject: Equatable {
      case action(rowId: Int)
      case control
    }

    let id: String
    let subject: Subject
    let tabId: String
    let sessionId: String
    /// What the person is asked to allow, quoted exactly.
    let text: String
    let epoch: UInt64
    let createdAt: Double
    /// A key press with no target goes to whatever has the focus, so moving the focus changes it.
    var tracksFocus = false
  }

  enum Decision: Equatable {
    case allow
    case deny
    /// The page or the control it was asked under is gone; the reason names which.
    case stale(String)
  }

  private(set) var items: [Item] = []
  /// Where an action's decision waits for the code that holds the quoted row.
  private final class Gate {
    var decision: Decision?
    var continuation: CheckedContinuation<Decision, Never>?
  }

  private var gates: [String: Gate] = [:]
  /// Answers to decided actions, so a replayed decision gets the same answer and nothing runs.
  private var decided: [String: JSON] = [:]
  private var decidedOrder: [String] = []
  private var nextControl = 1
  var onChange: (() -> Void)?
  /// Whether the last item to leave was withdrawn (a takeover, a closed page) rather than decided.
  private(set) var lastWasStale = false

  func openControl(tabId: String, sessionId: String, text: String, epoch: UInt64) -> String {
    if let existing = items.first(where: {
      $0.subject == .control && $0.tabId == tabId && $0.sessionId == sessionId
    }) {
      return existing.id
    }
    let id = "c\(nextControl)"
    nextControl += 1
    items.append(
      Item(
        id: id, subject: .control, tabId: tabId, sessionId: sessionId, text: text, epoch: epoch,
        createdAt: Date().timeIntervalSince1970))
    Log.info(.approvals, "open id=\(id) kind=control tab=\(tabId)")
    onChange?()
    return id
  }

  /// Lists a quoted action for the person to decide. The caller then awaits `decision(of:)`.
  func hold(
    rowId: Int, tabId: String, sessionId: String, text: String, epoch: UInt64,
    tracksFocus: Bool = false
  ) -> String {
    // The row id outlives a restart, so a decision aimed at a pre-restart item cannot reach a new one.
    let id = "a\(rowId)"
    gates[id] = Gate()
    items.append(
      Item(
        id: id, subject: .action(rowId: rowId), tabId: tabId, sessionId: sessionId, text: text,
        epoch: epoch, createdAt: Date().timeIntervalSince1970, tracksFocus: tracksFocus))
    Log.info(.approvals, "open id=\(id) kind=action tab=\(tabId)")
    onChange?()
    return id
  }

  /// Waits for the person, or for the item to go stale. Answers at once if it already has.
  func decision(of id: String) async -> Decision {
    guard let gate = gates[id] else { return .stale("unknown approval") }
    defer { gates[id] = nil }
    if let decision = gate.decision { return decision }
    return await withCheckedContinuation { gate.continuation = $0 }
  }

  func item(_ id: String) -> Item? { items.first { $0.id == id } }

  /// Removes the item and, for an action, lets its waiter go on. Returns nil when it was already
  /// decided.
  @discardableResult
  func resolve(_ id: String, _ decision: Decision) -> Item? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    let item = items.remove(at: index)
    if case .stale = decision { lastWasStale = true } else { lastWasStale = false }
    Log.info(.approvals, "resolve id=\(id) decision=\(Self.name(decision))")
    if case .action(let rowId) = item.subject {
      remember(id, Self.answer(item, rowId: rowId, decision))
      if let gate = gates[id] {
        gate.decision = decision
        gate.continuation?.resume(returning: decision)
        gate.continuation = nil
      }
    }
    onChange?()
    return item
  }

  /// The answer a replayed decision on an action gets, or nil for an id never seen (or a control
  /// request, which is answered once).
  func answer(for id: String) -> JSON? { decided[id] }

  /// Drops what `lookup` says can no longer be honoured: a closed page, a takeover, a handoff.
  func reap(_ lookup: (String) -> Tab?) {
    for item in items {
      guard let tab = lookup(item.tabId) else {
        resolve(item.id, .stale("tab closed"))
        continue
      }
      guard case .action = item.subject else { continue }
      if tab.control.epoch != item.epoch {
        resolve(item.id, .stale(StaleReason.epoch.rawValue))
      } else if tab.control.controller != .agent(item.sessionId) {
        resolve(item.id, .stale(StaleReason.notInControl.rawValue))
      }
    }
  }

  /// The reasons are fixed words (`StaleReason`, "tab closed", "run-ended"), never page text.
  private static func name(_ decision: Decision) -> String {
    switch decision {
    case .allow: "allow"
    case .deny: "deny"
    case .stale(let why): "stale:\(why)"
    }
  }

  static func json(_ item: Item) -> JSON {
    var fields: [String: JSON] = [
      "approvalId": .string(item.id), "tabId": .string(item.tabId),
      "sessionId": .string(item.sessionId), "text": .string(item.text),
      "createdAt": .number(item.createdAt),
    ]
    switch item.subject {
    case .action(let rowId):
      fields["kind"] = "action"
      fields["actionId"] = .number(Double(rowId))
    case .control:
      fields["kind"] = "control"
    }
    return .object(fields)
  }

  private static func answer(_ item: Item, rowId: Int, _ decision: Decision) -> JSON {
    let state: String
    switch decision {
    case .allow: state = "allowed"
    case .deny: state = "denied"
    case .stale: state = "cancelled"
    }
    var fields: [String: JSON] = [
      "approvalId": .string(item.id), "kind": "action", "actionId": .number(Double(rowId)),
      "state": .string(state),
    ]
    if case .stale(let why) = decision { fields["reason"] = .string("stale: \(why)") }
    return .object(fields)
  }

  private func remember(_ id: String, _ answer: JSON) {
    decided[id] = answer
    decidedOrder.append(id)
    if decidedOrder.count > 256 { decided[decidedOrder.removeFirst()] = nil }
  }
}
