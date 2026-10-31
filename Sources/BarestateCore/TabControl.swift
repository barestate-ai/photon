/// Who may act on a tab right now, and the counter that invalidates anything observed before a
/// human touched it (architecture §5.3).
public struct TabControl: Sendable, Equatable {
  public enum Controller: Sendable, Equatable {
    case human
    case agent(String)
  }

  public private(set) var epoch: UInt64 = 0
  public private(set) var controller: Controller = .human

  public init() {}

  public mutating func humanInput() {
    epoch += 1
    controller = .human
  }

  public mutating func grant(session: String) {
    controller = .agent(session)
  }

  public mutating func handoff() {
    controller = .human
  }

  /// The check made on the main actor immediately before each write. `current` is what the page
  /// looks like now; `observation` is what the action was planned against.
  public func admit(session: String, observation: Observation, current: PageKeys) -> Admission {
    if observation.epoch != epoch { return .stale(.epoch) }
    if controller != .agent(session) { return .stale(.notInControl) }
    if observation.documentKey != current.documentKey { return .stale(.documentKey) }
    if observation.viewportKey != current.viewportKey { return .stale(.viewportKey) }
    return .ok
  }
}

/// Why an action planned earlier may no longer be delivered.
public enum StaleReason: String, Sendable, Equatable {
  case epoch
  case notInControl = "not-in-control"
  case documentKey
  case viewportKey
  /// An element picked by its words from the observation no longer shows them.
  case target
}

public enum Admission: Sendable, Equatable {
  case ok
  case stale(StaleReason)
}
