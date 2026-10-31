import BarestateCore
import Foundation
import Testing

struct MuseAvailabilityTests {
  @Test func causesAreCheckedInOrderKeyThenPathThenTheLatch() {
    #expect(MuseAvailability.cause(hasKey: true, pathSatisfied: true, latched: false) == nil)
    #expect(MuseAvailability.cause(hasKey: false, pathSatisfied: true, latched: false) == .noKey)
    #expect(MuseAvailability.cause(hasKey: false, pathSatisfied: false, latched: true) == .noKey)
    #expect(MuseAvailability.cause(hasKey: true, pathSatisfied: false, latched: true) == .offline)
    #expect(
      MuseAvailability.cause(hasKey: true, pathSatisfied: true, latched: true) == .unreachable)
  }

  @Test func retryNeverProbesWhileTheKeyOrThePathIsMissing() async {
    let probes = Probes()
    let probe: @Sendable () async -> Bool = {
      probes.add()
      return true
    }
    #expect(
      await MuseAvailability.retry(hasKey: false, pathSatisfied: true, probe: probe) == .noKey)
    #expect(
      await MuseAvailability.retry(hasKey: true, pathSatisfied: false, probe: probe) == .offline)
    #expect(probes.count == 0)
  }

  @Test func retryClearsOnlyWhenTheProbeAnswers() async {
    #expect(
      await MuseAvailability.retry(hasKey: true, pathSatisfied: true, probe: { false })
        == .unreachable)
    #expect(await MuseAvailability.retry(hasKey: true, pathSatisfied: true, probe: { true }) == nil)
  }

  @Test(arguments: [
    (ModelError.unreachable, true), (.timeout, true), (.server(status: 503), true),
    (.server(status: 500), true), (.server(status: 429), false), (.noKey, false),
    (.rejected(status: 400, message: ""), false), (.malformed("x"), false),
    (.refused("run ended"), false), (.capReached(total: 40), false),
  ])
  func onlyTransportFailuresAndServerFaultsAreAnOutage(error: ModelError, outage: Bool) {
    #expect(error.isOutage == outage)
  }
}

private final class Probes: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func add() { lock.withLock { calls += 1 } }
  var count: Int { lock.withLock { calls } }
}
