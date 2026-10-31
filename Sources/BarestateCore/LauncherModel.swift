import Foundation

/// What the launcher shows and which row Return would run. Results come back from a background
/// ranking task tagged with the generation that asked for them, so a slow answer to an older
/// query can never replace newer rows or move the active row.
public struct LauncherModel: Sendable {
  public static let unavailableSubtitle = "Muse is unavailable. Web search still works."

  public private(set) var query = ""
  public private(set) var scope = LauncherScope.all
  public private(set) var generation = 0
  public private(set) var appliedGeneration = 0
  public private(set) var rows: [LauncherRow] = []
  public private(set) var activeId: String?
  public private(set) var taskUnavailable = false
  private var base: [LauncherRow] = []
  /// The query the current rows answer.
  public private(set) var rankedQuery: String?

  public init() {}

  public var isCurrent: Bool { appliedGeneration == generation }

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

  /// With no model to run it, Start task stays visible but cannot be chosen, and a typed request
  /// gets a Retry row right after it.
  public mutating func setTaskUnavailable(_ on: Bool) {
    guard on != taskUnavailable else { return }
    taskUnavailable = on
    rebuild(keepActive: true)
  }

  /// A committed row consumes the query; anything else leaves it for the next open. A scope's
  /// query belongs to that scope and never outlives it.
  public mutating func close(committed: Bool) {
    taskUnavailable = false
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
      guard taskUnavailable, row.kind == .startTask else {
        rows.append(row)
        continue
      }
      var disabled = row
      disabled.subtitle = Self.unavailableSubtitle
      disabled.enabled = false
      rows.append(disabled)
      if row.section == LauncherRanking.requestSection, !rows.contains(where: { $0.kind == .retry })
      {
        rows.append(
          LauncherRow(
            section: row.section, kind: .retry, title: "Retry",
            subtitle: "Connect to Muse again", actionLabel: "Retry", target: ""))
      }
    }
    if keepActive, let activeId, rows.contains(where: { $0.id == activeId && $0.enabled }) {
      return
    }
    activeId = rows.first { $0.enabled && $0.kind != .retry }?.id
  }
}
