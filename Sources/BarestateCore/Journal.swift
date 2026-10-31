import CryptoKit
import Foundation
import SQLite3

public enum ActionState: String, Sendable {
  case quoted, pending, confirmed, failed, cancelled
  case outcomeUnknown = "outcome-unknown"
}

/// What the journal records before anything is dispatched.
public struct NewAction: Sendable {
  public let sessionId: String
  public let clientActionId: String
  public let tabId: String?
  public let epoch: UInt64?
  public let observationId: String
  public let kind: String
  public let target: String
  public let textHash: String?
  public let rung: String?

  public init(
    sessionId: String, clientActionId: String, tabId: String?, epoch: UInt64?,
    observationId: String, kind: String, target: String, textHash: String?, rung: String? = nil
  ) {
    self.rung = rung
    self.sessionId = sessionId
    self.clientActionId = clientActionId
    self.tabId = tabId
    self.epoch = epoch
    self.observationId = observationId
    self.kind = kind
    self.target = target
    self.textHash = textHash
  }

  /// Typed text never reaches the journal, only this digest.
  public static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ActionRow: Sendable, Equatable {
  public let id: Int
  public let sessionId: String
  public let clientActionId: String
  public let tabId: String?
  public let epoch: UInt64?
  public let observationId: String?
  public let kind: String
  public let target: String
  public let textHash: String?
  public let state: ActionState
  public let reason: String?
  public let domVerdict: String?
  public let modelVerdict: String?
  public let sensitive: Bool
  /// SHA-256 of the binding an Allow once was minted for; set when the row is quoted. Kept out of
  /// `json`: no socket, MCP or phone client has a use for it.
  public let approvalTokenHash: String?
  /// Which part of the instruction ladder found the target (`ref` when the caller named it).
  public let rung: String?
  public let createdAt: Double
  public let updatedAt: Double

  public var json: JSON {
    var fields: [String: JSON] = [
      "id": .number(Double(id)), "sessionId": .string(sessionId),
      "clientActionId": .string(clientActionId), "kind": .string(kind), "target": .string(target),
      "state": .string(state.rawValue), "createdAt": .number(createdAt),
      "updatedAt": .number(updatedAt),
    ]
    if let tabId { fields["tabId"] = .string(tabId) }
    if let epoch { fields["epoch"] = .number(Double(epoch)) }
    if let observationId { fields["observationId"] = .string(observationId) }
    if let reason { fields["reason"] = .string(reason) }
    if let domVerdict { fields["domVerdict"] = .string(domVerdict) }
    if let modelVerdict { fields["modelVerdict"] = .string(modelVerdict) }
    if sensitive { fields["sensitive"] = true }
    if let rung { fields["rung"] = .string(rung) }
    return .object(fields)
  }
}

/// The journal (architecture §5.5). A row exists before anything is dispatched, and
/// (session, clientActionId) is unique, so repeating a call can never repeat an effect.
extension Store {
  private static let actionColumns =
    "id, session_id, client_action_id, tab_id, epoch, observation_id, kind, target, text_hash, "
    + "state, reason, dom_verdict, created_at, updated_at, rung, model_verdict, sensitive, "
    + "approval_token_hash"

  /// Inserts the row as `pending`, or returns the one that already exists for the pair.
  public func record(_ new: NewAction, now: Double = Date().timeIntervalSince1970) throws -> (
    row: ActionRow, created: Bool
  ) {
    try run(
      """
      INSERT OR IGNORE INTO actions(session_id, client_action_id, tab_id, epoch, observation_id,
        kind, target, text_hash, state, sensitive, created_at, updated_at, rung)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'pending', 0, ?9, ?9, ?10)
      """
    ) { statement in
      bind(statement, 1, new.sessionId)
      bind(statement, 2, new.clientActionId)
      bind(statement, 3, new.tabId)
      if let epoch = new.epoch {
        sqlite3_bind_int64(statement, 4, Int64(epoch))
      } else {
        sqlite3_bind_null(statement, 4)
      }
      bind(statement, 5, new.observationId)
      bind(statement, 6, new.kind)
      bind(statement, 7, new.target)
      bind(statement, 8, new.textHash)
      sqlite3_bind_double(statement, 9, now)
      bind(statement, 10, new.rung)
    }
    let created = sqlite3_changes(db) == 1
    guard let row = action(sessionId: new.sessionId, clientActionId: new.clientActionId) else {
      throw Failure(message: "the journal row was not found after insert")
    }
    return (row, created)
  }

  /// Names the target an instruction resolved to and the rung that found it.
  public func resolve(id: Int, target: String, rung: String) throws {
    try run(
      "UPDATE actions SET target = ?2, rung = ?3 WHERE id = ?1 AND state IN ('quoted', 'pending')"
    ) {
      statement in
      sqlite3_bind_int64(statement, 1, Int64(id))
      bind(statement, 2, target)
      bind(statement, 3, rung)
    }
  }

  /// Holds a `pending` row for a human's Allow once, bound to `tokenHash`. Nothing has reached the
  /// page.
  public func quote(
    id: Int, tokenHash: String, sensitive: Bool, reason: String?,
    now: Double = Date().timeIntervalSince1970
  ) throws -> ActionRow {
    try run(
      """
      UPDATE actions SET state = 'quoted', sensitive = ?2, approval_token_hash = ?3, reason = ?4,
        updated_at = ?5 WHERE id = ?1 AND state = 'pending'
      """
    ) { statement in
      sqlite3_bind_int64(statement, 1, Int64(id))
      sqlite3_bind_int(statement, 2, sensitive ? 1 : 0)
      bind(statement, 3, tokenHash)
      bind(statement, 4, reason)
      sqlite3_bind_double(statement, 5, now)
    }
    guard let row = action(id: id) else { throw Failure(message: "no action \(id)") }
    return row
  }

  /// Moves a `quoted` row to `pending`, once: false means it was already decided or ended.
  public func approve(id: Int, now: Double = Date().timeIntervalSince1970) throws -> Bool {
    try run(
      "UPDATE actions SET state = 'pending', reason = NULL, updated_at = ?2 WHERE id = ?1 AND state = 'quoted'"
    ) { statement in
      sqlite3_bind_int64(statement, 1, Int64(id))
      sqlite3_bind_double(statement, 2, now)
    }
    return sqlite3_changes(db) == 1
  }

  /// Ends a `quoted` or `pending` row. A row that already ended is returned unchanged.
  public func settle(
    id: Int, state: ActionState, reason: String?, domVerdict: String?,
    modelVerdict: String? = nil, now: Double = Date().timeIntervalSince1970
  ) throws -> ActionRow {
    try run(
      """
      UPDATE actions SET state = ?2, reason = ?3, dom_verdict = ?4, model_verdict = ?6,
        updated_at = ?5 WHERE id = ?1 AND state IN ('quoted', 'pending')
      """
    ) { statement in
      sqlite3_bind_int64(statement, 1, Int64(id))
      bind(statement, 2, state.rawValue)
      bind(statement, 3, reason)
      bind(statement, 4, domVerdict)
      sqlite3_bind_double(statement, 5, now)
      bind(statement, 6, modelVerdict)
    }
    guard let row = action(id: id) else { throw Failure(message: "no action \(id)") }
    return row
  }

  public func action(id: Int) -> ActionRow? {
    actions("WHERE id = ?1") { sqlite3_bind_int64($0, 1, Int64(id)) }.first
  }

  public func action(sessionId: String, clientActionId: String) -> ActionRow? {
    actions("WHERE session_id = ?1 AND client_action_id = ?2") {
      bind($0, 1, sessionId)
      bind($0, 2, clientActionId)
    }.first
  }

  private func actions(_ filter: String, bind: (OpaquePointer?) -> Void) -> [ActionRow] {
    var statement: OpaquePointer?
    guard let db = openDB,
      sqlite3_prepare_v2(
        db, "SELECT \(Self.actionColumns) FROM actions \(filter)", -1, &statement, nil)
        == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    var rows: [ActionRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let state = ActionState(rawValue: text(statement, 9) ?? "") else { continue }
      rows.append(
        ActionRow(
          id: Int(sqlite3_column_int64(statement, 0)), sessionId: text(statement, 1) ?? "",
          clientActionId: text(statement, 2) ?? "", tabId: text(statement, 3),
          epoch: sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : UInt64(sqlite3_column_int64(statement, 4)),
          observationId: text(statement, 5), kind: text(statement, 6) ?? "",
          target: text(statement, 7) ?? "", textHash: text(statement, 8), state: state,
          reason: text(statement, 10), domVerdict: text(statement, 11),
          modelVerdict: text(statement, 15), sensitive: sqlite3_column_int(statement, 16) != 0,
          approvalTokenHash: text(statement, 17), rung: text(statement, 14),
          createdAt: sqlite3_column_double(statement, 12),
          updatedAt: sqlite3_column_double(statement, 13)))
    }
    return rows
  }
}

private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
  if let value {
    sqlite3_bind_text(statement, index, value, -1, Store.transient)
  } else {
    sqlite3_bind_null(statement, index)
  }
}

private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
  sqlite3_column_text(statement, column).map { String(cString: $0) }
}
