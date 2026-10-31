/// Why Start task cannot reach Muse, in the order the causes are checked.
public enum MuseOutage: Equatable, Sendable {
  case noKey
  /// The system has no network path.
  case offline
  /// A model call failed as an outage and Retry has not yet reached the provider.
  case unreachable
}

public enum MuseAvailability {
  public static func cause(hasKey: Bool, pathSatisfied: Bool, latched: Bool) -> MuseOutage? {
    if !hasKey { return .noKey }
    if !pathSatisfied { return .offline }
    return latched ? .unreachable : nil
  }

  /// Retry: the local causes are re-checked first, so a missing key or a dead path never sends a
  /// request; only then does the probe decide.
  public static func retry(
    hasKey: Bool, pathSatisfied: Bool, probe: @Sendable () async -> Bool
  ) async -> MuseOutage? {
    if let local = cause(hasKey: hasKey, pathSatisfied: pathSatisfied, latched: false) {
      return local
    }
    return await probe() ? nil : .unreachable
  }
}
