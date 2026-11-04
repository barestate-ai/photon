import Foundation

/// What the launcher shows and which row Return would run. Results come back from a background
/// ranking task tagged with the generation that asked for them, so a slow answer to an older
/// query can never replace newer rows or move the active row.
public struct LauncherModel: Sendable {
  /// What a disabled Start task row says: why Muse cannot be reached, and what to do about it.
  public static func unavailableSubtitle(_ cause: MuseOutage) -> String {
    switch cause {
    case .noKey:
      """
      No model key. Use Barestate Muse in Settings (⌘,). \
      Settings also lists where else a key can go.
      """
    case .offline: "No network connection. Reconnect and try again."
    case .unreachable: "Muse cannot be reached. Web search still works."
    }
  }

  private static let retrySubtitle = "Connect to Muse again"
  /// Retry looked again and found Muse still down.
  private static let recheckedSubtitle = "Checked again. Still unavailable."

  public private(set) var query = ""
  public private(set) var scope = LauncherScope.all
  public private(set) var generation = 0
  public private(set) var appliedGeneration = 0
  public private(set) var rows: [LauncherRow] = []
  public private(set) var activeId: String?
  /// Why Start task cannot run, if it cannot.
  public private(set) var outage: MuseOutage?
  /// Retry has looked again since the outage appeared and found it still there.
  public private(set) var rechecked = false
  private var base: [LauncherRow] = []
  /// The query the current rows answer.
  public private(set) var rankedQuery: String?

  public init() {}

  public var isCurrent: Bool { appliedGeneration == generation }

  public var taskUnavailable: Bool { outage != nil }

  public var activeRow: LauncherRow? {
    rows.first { $0.id == activeId }
  }

  /// Returns the generation the answer must carry.
  public mutating func setQuery(_ text: String) -> Int {
    query = text
    return refresh()
  }

  /// Entering or leaving a scope starts a fresh, empty query.
  public mutating func setScope(_ scope: LauncherScope) -> Int {
    self.scope = scope
    rankedQuery = nil
    return setQuery("")
  }

  /// The data behind the same query changed: ask again, and keep the active row if it survives.
  public mutating func refresh() -> Int {
    generation += 1
    return generation
  }

  /// A new open starts on the first row, whichever row was active when it last closed.
  public mutating func reopen() -> Int {
    rankedQuery = nil
    return refresh()
  }

  @discardableResult
  public mutating func apply(_ result: LauncherResult) -> Bool {
    guard result.generation == generation else { return false }
    let sameQuery = rankedQuery == result.query
    appliedGeneration = result.generation
    rankedQuery = result.query
    base = result.rows
    rebuild(keepActive: sameQuery)
    return true
  }

  public mutating func moveActive(by step: Int) {
    let enabled = rows.filter(\.enabled)
    guard !enabled.isEmpty else { return }
    let index = enabled.firstIndex { $0.id == activeId } ?? 0
    activeId = enabled[min(max(index + step, 0), enabled.count - 1)].id
  }

  public mutating func activate(_ id: String) {
    if rows.contains(where: { $0.id == id && $0.enabled }) { activeId = id }
  }

  /// With no model to run it, Start task stays visible but cannot be chosen, says why, and a typed
  /// request gets a Retry row right after it. `rechecked` is Retry reporting the same outage.
  public mutating func setOutage(_ cause: MuseOutage?, rechecked: Bool = false) {
    let rechecked = cause != nil && rechecked
    guard cause != outage || rechecked != self.rechecked else { return }
    outage = cause
    self.rechecked = rechecked
    rebuild(keepActive: true)
  }

  /// A committed row consumes the query; anything else leaves it for the next open. A scope's
  /// query belongs to that scope and never outlives it.
  public mutating func close(committed: Bool) {
    outage = nil
    rechecked = false
    rebuild(keepActive: true)
    guard committed || scope != .all else { return }
    scope = .all
    query = ""
    rows = []
    base = []
    activeId = nil
    rankedQuery = nil
    generation += 1
    appliedGeneration = generation
  }

  private mutating func rebuild(keepActive: Bool) {
    rows = []
    for row in base {
      guard let outage, row.kind == .startTask else {
        rows.append(row)
        continue
      }
      var disabled = row
      disabled.subtitle = Self.unavailableSubtitle(outage)
      disabled.enabled = false
      rows.append(disabled)
      if row.section == LauncherRanking.requestSection, !rows.contains(where: { $0.kind == .retry })
      {
        rows.append(
          LauncherRow(
            section: row.section, kind: .retry, title: "Retry",
            subtitle: rechecked ? Self.recheckedSubtitle : Self.retrySubtitle,
            actionLabel: "Retry", target: ""))
      }
    }
    if keepActive, let activeId, rows.contains(where: { $0.id == activeId && $0.enabled }) {
      return
    }
    activeId = rows.first { $0.enabled && $0.kind != .retry }?.id
  }
}
