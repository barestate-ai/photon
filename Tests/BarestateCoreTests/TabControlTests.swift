import BarestateCore
import Testing

struct TabControlTests {
  @Test func humanInputBumpsTheEpochAndTakesControl() {
    var control = TabControl()
    control.grant(session: "s1")
    #expect(control.controller == .agent("s1"))
    let before = control.epoch
    control.humanInput()
    #expect(control.epoch == before + 1)
    #expect(control.controller == .human)
  }

  @Test func handoffReturnsControlWithoutChangingTheEpoch() {
    var control = TabControl()
    control.grant(session: "s1")
    let epoch = control.epoch
    control.handoff()
    #expect(control.controller == .human)
    #expect(control.epoch == epoch)
  }

  private let keys = PageKeys(documentKey: "F:L1", viewportKey: "0,0,1100x720@1")

  private func observation(epoch: UInt64, keys: PageKeys) -> Observation {
    Observation(
      id: "o1", tabId: "t1", epoch: epoch, documentKey: keys.documentKey,
      viewportKey: keys.viewportKey, url: "", title: "", elements: [])
  }

  private func granted(_ session: String = "s1") -> TabControl {
    var control = TabControl()
    control.grant(session: session)
    return control
  }

  @Test func admitsAnActionPlannedAgainstTheCurrentState() {
    let control = granted()
    let planned = observation(epoch: control.epoch, keys: keys)
    #expect(control.admit(session: "s1", observation: planned, current: keys) == .ok)
  }

  @Test func humanInputMakesEarlierObservationsStaleEvenAfterARegrant() {
    var control = granted()
    let planned = observation(epoch: control.epoch, keys: keys)
    control.humanInput()
    #expect(
      control.admit(session: "s1", observation: planned, current: keys) == .stale(.epoch))
    control.grant(session: "s1")
    #expect(
      control.admit(session: "s1", observation: planned, current: keys) == .stale(.epoch))
  }

  @Test func writesNeedTheCallingSessionsGrant() {
    let human = TabControl()
    let planned = observation(epoch: 0, keys: keys)
    #expect(
      human.admit(session: "s1", observation: planned, current: keys) == .stale(.notInControl))
    #expect(
      granted("other").admit(session: "s1", observation: planned, current: keys)
        == .stale(.notInControl))
  }

  @Test func handoffBetweenPlanningAndSendingFencesTheAction() {
    var control = granted()
    let planned = observation(epoch: control.epoch, keys: keys)
    control.handoff()
    #expect(
      control.admit(session: "s1", observation: planned, current: keys) == .stale(.notInControl))
  }

  @Test func aNewDocumentOrAScrolledViewportIsStale() {
    let control = granted()
    let planned = observation(epoch: control.epoch, keys: keys)
    let navigated = PageKeys(documentKey: "F:L2", viewportKey: keys.viewportKey)
    let scrolled = PageKeys(documentKey: keys.documentKey, viewportKey: "0,50,1100x720@1")
    #expect(
      control.admit(session: "s1", observation: planned, current: navigated)
        == .stale(.documentKey))
    #expect(
      control.admit(session: "s1", observation: planned, current: scrolled)
        == .stale(.viewportKey))
  }
}
