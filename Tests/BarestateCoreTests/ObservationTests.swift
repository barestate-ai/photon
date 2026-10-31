import BarestateCore
import Foundation
import Testing

/// Replies captured from the real engine on fixtures/observe.html.
private let captured: JSON = {
  let url = Bundle.module.url(
    forResource: "observe-fixture", withExtension: "json", subdirectory: "Fixtures")!
  return JSON.parse(try! Data(contentsOf: url))!
}()

private func raw(scrollY: Double = 0, loaderId: String? = nil, width: Double? = nil)
  -> RawObservation
{
  var metrics = captured["metrics"]!.object!
  if scrollY != 0 || width != nil {
    var viewport = metrics["cssVisualViewport"]!.object!
    viewport["pageY"] = .number(scrollY)
    metrics["cssVisualViewport"] = .object(viewport)
    var layout = metrics["cssLayoutViewport"]!.object!
    if let width { layout["clientWidth"] = .number(width) }
    metrics["cssLayoutViewport"] = .object(layout)
  }
  var frame = captured["frametree"]!
  if let loaderId {
    var fields = frame["frameTree"]!["frame"]!.object!
    fields["loaderId"] = .string(loaderId)
    frame = ["frameTree": ["frame": .object(fields)]]
  }
  return RawObservation(
    snapshot: captured["snapshot"]!, ax: captured["ax"]!, metrics: .object(metrics),
    frameTree: frame, dpr: 1)
}

private func build(_ raw: RawObservation = raw()) throws -> Observation {
  try Observation.build(id: "o1", tabId: "t1", epoch: 3, raw: raw)
}

private func element(_ observation: Observation, named name: String) -> Element? {
  observation.elements.first { $0.name == name }
}

struct ObservationTests {
  @Test func carriesTheEnvelope() throws {
    let observation = try build()
    #expect(observation.id == "o1")
    #expect(observation.tabId == "t1")
    #expect(observation.epoch == 3)
    #expect(observation.url == "http://127.0.0.1:47810/observe.html")
    #expect(
      observation.documentKey == "D6DF44C9C60D7DFBDF5D07F5AF8AAB40:7BAABBD7F582946FF84505DE2390A4C9"
    )
    #expect(observation.viewportKey == "0,0,1100x720@1")
  }

  @Test func interactiveElementsCarryRefRoleNameAndBounds() throws {
    let observation = try build()
    let button = try #require(element(observation, named: "Go"))
    #expect(button.ref == 8)
    #expect(button.role == "button")
    #expect(button.interactive)
    #expect(button.bounds == Rect(x: 24, y: 82.4375, w: 33.796875, h: 21))
    let input = try #require(element(observation, named: "Full name"))
    #expect(input.role == "textbox")
    #expect(input.interactive)
    let link = try #require(element(observation, named: "More details"))
    #expect(link.role == "link")
    #expect(link.interactive)
  }

  @Test func invisibleControlsAreListedButNotInteractive() throws {
    let observation = try build()
    let hidden = try #require(element(observation, named: "Hidden action"))
    #expect(!hidden.interactive)
    #expect(hidden.role == "button")
    let faded = try #require(element(observation, named: "Faded action"))
    #expect(!faded.interactive)
  }

  @Test func sensitiveFlagsFollowTheClassifier() throws {
    let observation = try build()
    #expect(try #require(element(observation, named: "Password")).sensitive)
    #expect(try #require(element(observation, named: "Place order")).sensitive)
    #expect(!(try #require(element(observation, named: "Go")).sensitive))
    #expect(!(try #require(element(observation, named: "Full name")).sensitive))
  }

  @Test func plainTextAndWrapperNodesAreNotElements() throws {
    let observation = try build()
    #expect(
      !observation.elements.contains {
        ["StaticText", "InlineTextBox", "generic", "none"].contains($0.role)
      })
    #expect(observation.elements.map(\.ref) == [6, 8, 2, 12, 41, 14, 3, 4])
  }

  @Test func identicalRepliesGiveIdenticalKeys() throws {
    let first = try build()
    let second = try build()
    #expect(first.documentKey == second.documentKey)
    #expect(first.viewportKey == second.viewportKey)
  }

  @Test func aNewDocumentChangesTheDocumentKeyOnly() throws {
    let before = try build()
    let after = try build(raw(loaderId: "NEWLOADER"))
    #expect(after.documentKey != before.documentKey)
    #expect(after.viewportKey == before.viewportKey)
  }

  @Test func scrollingChangesTheViewportKeyAndShiftsBounds() throws {
    let before = try build()
    let after = try build(raw(scrollY: 50))
    #expect(after.viewportKey == "0,50,1100x720@1")
    #expect(after.documentKey == before.documentKey)
    let moved = try #require(element(after, named: "Go"))
    #expect(moved.bounds.y == 82.4375 - 50)
  }

  @Test func aPageCannotCrashTheKeyWithAnAbsurdPixelRatio() throws {
    var absurd = raw()
    absurd = RawObservation(
      snapshot: absurd.snapshot, ax: absurd.ax, metrics: absurd.metrics,
      frameTree: absurd.frameTree, dpr: 1e30)
    #expect(try build(absurd).viewportKey.hasPrefix("0,0,1100x720@"))
  }

  @Test func resizingChangesTheViewportKey() throws {
    #expect(try build(raw(width: 900)).viewportKey == "0,0,900x720@1")
  }

  @Test func aMalformedReplyIsAnErrorNotACrash() {
    let broken = RawObservation(
      snapshot: .object([:]), ax: .object([:]), metrics: .object([:]), frameTree: .object([:]),
      dpr: 1)
    #expect(throws: ObservationError.self) { try build(broken) }
  }
}
