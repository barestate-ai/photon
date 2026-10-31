import BarestateCore
import Foundation
import Testing

/// A browser behind a real `CDPChannel`: it records every message written and answers at once,
/// the way CEF does for browser-handled methods.
@MainActor
final class ScriptedPage {
  var written: [(method: String, params: JSON)] = []
  /// Values returned by successive `Runtime.callFunctionOn` calls.
  var scriptResults: [JSON]
  var failing: Set<String> = []
  /// Methods refused from their nth call on (1-based), the earlier ones having been answered.
  var refuseFrom: [String: Int] = [:]
  var refusal = "refused"
  /// Successive main-frame loader ids; the last one repeats.
  var loaders = ["L1"]
  /// Values returned by successive scroll-position `Runtime.evaluate` calls; every other
  /// evaluation answers 1.
  var evaluations: [JSON] = []
  var navigateReply = #"{"frameId":"F","loaderId":"L2"}"#
  private(set) var channel: CDPChannel!

  init(scriptResults: [JSON]) {
    self.scriptResults = scriptResults
    channel = CDPChannel { [weak self] text in self?.answer(text) ?? false }
  }

  var writes: [String] {
    written.map(\.method).filter { $0.hasPrefix("Input.") || $0 == "DOM.focus" }
  }

  private func answer(_ text: String) -> Bool {
    guard let message = JSON.parse(Data(text.utf8)), let id = message["id"]?.int,
      let method = message["method"]?.string
    else { return false }
    written.append((method, message["params"] ?? .null))
    let refused =
      failing.contains(method)
      || (refuseFrom[method].map { written.filter { $0.method == method }.count >= $0 } ?? false)
    var result = "{}"
    switch method {
    case "Page.getFrameTree":
      let loader = loaders.count > 1 ? loaders.removeFirst() : loaders[0]
      result = #"{"frameTree":{"frame":{"id":"F","loaderId":"\#(loader)"}}}"#
    case "Page.navigate": result = navigateReply
    case "Page.getLayoutMetrics":
      result =
        #"{"cssVisualViewport":{"pageX":0,"pageY":0},"cssLayoutViewport":{"clientWidth":1100,"clientHeight":720}}"#
    case "Runtime.evaluate":
      let expression = written.last?.params["expression"]?.string ?? ""
      let value =
        expression.contains("activeElement")
        ? scriptResults.removeFirst()
        : expression.contains("scrollY") && !evaluations.isEmpty ? evaluations.removeFirst() : 1
      result = #"{"result":{"value":\#(value.serialized())}}"#
    case "Page.createIsolatedWorld": result = #"{"executionContextId":7}"#
    case "DOM.resolveNode": result = #"{"object":{"objectId":"obj"}}"#
    case "Runtime.callFunctionOn":
      result = #"{"result":{"value":\#(scriptResults.removeFirst().serialized())}}"#
    default: break
    }
    if refused {
      channel.receive(Data(#"{"id":\#(id),"error":{"code":-32000,"message":"\#(refusal)"}}"#.utf8))
    } else {
      channel.receive(Data(#"{"id":\#(id),"result":\#(result)}"#.utf8))
    }
    return true
  }
}

private let spot: JSON = [
  "x": 50, "y": 20, "onscreen": true, "hit": true, "editable": true,
]

private func snapshot(
  href: String = "http://x/a", page: String = "p1", connected: Bool = true, shell: String = "s1",
  state: String = "false"
) -> JSON {
  [
    "href": .string(href), "page": .string(page), "connected": .bool(connected),
    "shell": .string(shell), "state": .string(state),
  ]
}

private let still = snapshot()
private let moved = snapshot(state: "true")

private func spotWith(_ changes: [String: JSON]) -> JSON {
  .object((spot.object ?? [:]).merging(changes) { $1 })
}

private func caret(_ value: String, _ start: Int, _ end: Int? = nil) -> JSON {
  ["value": .string(value), "start": .number(Double(start)), "end": .number(Double(end ?? start))]
}

@MainActor
struct DispatchTests {
  private let admitAll: Dispatch.Admit = { _ in nil }

  @Test func aClickPressesAndReleasesAtTheElementCenter() async throws {
    let page = ScriptedPage(scriptResults: [spot, still, moved])
    let outcome = try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    #expect(outcome.verified)
    let mouse = page.written.filter { $0.method == "Input.dispatchMouseEvent" }.map(\.params)
    #expect(mouse.map { $0["type"]?.string } == ["mousePressed", "mouseReleased"])
    for event in mouse {
      #expect(event["x"] == 50 && event["y"] == 20 && event["button"] == "left")
      #expect(event["clickCount"] == 1)
    }
  }

  @Test func admissionIsDecidedFromFreshKeysFirstAndAgainBeforeTheWrite() async throws {
    let page = ScriptedPage(scriptResults: [spot, still, moved])
    var seen: [PageKeys] = []
    let outcome = try await Dispatch.click(ref: 8, channel: page.channel) { keys in
      seen.append(keys)
      return nil
    }
    #expect(outcome.verified)
    let current = PageKeys(documentKey: "F:L1", viewportKey: "0,0,1100x720@1")
    #expect(seen == [current, current])
  }

  @Test func aStaleActionSendsNothingToThePage() async {
    let page = ScriptedPage(scriptResults: [spot])
    await #expect(throws: Dispatch.Stale(reason: .epoch)) {
      try await Dispatch.click(ref: 8, channel: page.channel) { _ in .epoch }
    }
    #expect(page.writes.isEmpty)
  }

  @Test func anElementCoveredByAnotherIsNotClicked() async {
    let page = ScriptedPage(scriptResults: [spotWith(["hit": false])])
    await #expect(
      throws: Dispatch.Failure(message: "covered by another element", effectPossible: false)
    ) {
      try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    }
    #expect(page.writes.isEmpty)
  }

  @Test func anElementOutsideTheViewportIsNotClicked() async {
    let page = ScriptedPage(scriptResults: [spotWith(["onscreen": false])])
    await #expect(throws: Dispatch.Failure(message: "outside the viewport", effectPossible: false))
    {
      try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    }
    #expect(page.writes.isEmpty)
  }

  @Test func aRefusedPressIsAFailureAndTheReleaseStillFollows() async {
    let page = ScriptedPage(scriptResults: [spot, still])
    page.failing = ["Input.dispatchMouseEvent"]
    await #expect(throws: Dispatch.Failure.self) {
      try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    }
    #expect(page.writes == ["Input.dispatchMouseEvent", "Input.dispatchMouseEvent"])
  }

  @Test func aPressThatLandedWhoseReleaseFailedMayHaveHadAnEffect() async {
    let page = ScriptedPage(scriptResults: [spot, still])
    page.refuseFrom = ["Input.dispatchMouseEvent": 2]
    await #expect(
      throws: Dispatch.Failure(
        message: "Input.dispatchMouseEvent: remote(code: -32000, message: \"refused\")",
        effectPossible: true)
    ) {
      try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    }
  }

  @Test func aClickIsVerifiedByWhatItChanged() async throws {
    let changed = ScriptedPage(scriptResults: [spot, still, snapshot(page: "p2")])
    let outcome = try await Dispatch.click(ref: 8, channel: changed.channel, admit: admitAll)
    #expect(outcome.verified && outcome.verdict == "page-changed")
    let nothing = ScriptedPage(scriptResults: [spot, still, still])
    let idle = try await Dispatch.click(ref: 8, channel: nothing.channel, admit: admitAll)
    #expect(!idle.verified && idle.verdict == "unchanged")
  }

  @Test func aClickThatBroughtANewDocumentIsVerifiedWithoutReadingTheOldNode() async throws {
    let page = ScriptedPage(scriptResults: [spot, still])
    page.loaders = ["L1", "L1", "L1", "L1", "L2"]
    let outcome = try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    #expect(outcome.verdict == "document-changed")
  }

  @Test func aNodeThePageRemovedReadsAsGone() async throws {
    let page = ScriptedPage(scriptResults: [spot, still])
    page.refuseFrom = ["DOM.resolveNode": 3]
    page.refusal = "Could not find node with given id"
    let outcome = try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    #expect(outcome.verdict == "element-gone")
  }

  @Test func aReadThatFailedForAnyOtherReasonIsNotAnEffect() async {
    let page = ScriptedPage(scriptResults: [spot, still])
    page.refuseFrom = ["DOM.resolveNode": 3]
    await #expect(throws: Dispatch.Failure.self) {
      try await Dispatch.click(ref: 8, channel: page.channel, admit: admitAll)
    }
  }

  @Test func typingFocusesTheNodeThenInsertsTheText() async throws {
    let page = ScriptedPage(scriptResults: [spot, true, caret("", 0), "hello"])
    let outcome = try await Dispatch.type(
      ref: 2, text: "hello", channel: page.channel, admit: admitAll)
    #expect(outcome.verified)
    #expect(page.writes == ["DOM.focus", "Input.insertText"])
    #expect(page.written.first { $0.method == "DOM.focus" }?.params["backendNodeId"] == 2)
    #expect(page.written.first { $0.method == "Input.insertText" }?.params["text"] == "hello")
  }

  @Test func typingChecksAdmissionBeforeEachWrite() async {
    let page = ScriptedPage(scriptResults: [spot, true, caret("", 0), "hello"])
    var calls = 0
    await #expect(throws: Dispatch.Stale(reason: .notInControl)) {
      try await Dispatch.type(ref: 2, text: "hello", channel: page.channel) { _ in
        calls += 1
        return calls == 3 ? .notInControl : nil
      }
    }
    #expect(page.writes == ["DOM.focus"])
  }

  @Test func textIsNotInsertedWhenThePageMovedFocusAwayFromTheTarget() async {
    let page = ScriptedPage(scriptResults: [spot, false])
    await #expect(
      throws: Dispatch.Failure(message: Dispatch.focusRedirected, effectPossible: false)
    ) {
      try await Dispatch.type(ref: 2, text: "hello", channel: page.channel, admit: admitAll)
    }
    #expect(page.writes == ["DOM.focus"])
  }

  @Test func aTakeoverThatMovedFocusIsStaleNotRedirected() async {
    let page = ScriptedPage(scriptResults: [spot, false])
    var calls = 0
    await #expect(throws: Dispatch.Stale(reason: .epoch)) {
      try await Dispatch.type(ref: 2, text: "hello", channel: page.channel) { _ in
        calls += 1
        return calls == 3 ? .epoch : nil
      }
    }
    #expect(page.writes == ["DOM.focus"])
  }

  @Test func aValueThatLacksTheTextIsNotVerified() async throws {
    let page = ScriptedPage(scriptResults: [spot, true, caret("", 0), ""])
    let outcome = try await Dispatch.type(
      ref: 2, text: "hello", channel: page.channel, admit: admitAll)
    #expect(!outcome.verified)
  }

  @Test func theTextMustLandAtTheCaretNotJustSomewhere() async throws {
    let inserted = ScriptedPage(scriptResults: [spot, true, caret("abcd", 2), "abXYcd"])
    let good = try await Dispatch.type(
      ref: 2, text: "XY", channel: inserted.channel, admit: admitAll)
    #expect(good.verified && good.verdict == "value-matches")
    for value in ["abcdXY", "XYabcd", "abXYcdXY", "abXcd"] {
      let page = ScriptedPage(scriptResults: [spot, true, caret("abcd", 2), .string(value)])
      let outcome = try await Dispatch.type(
        ref: 2, text: "XY", channel: page.channel, admit: admitAll)
      #expect(!outcome.verified, "\(value)")
    }
  }

  @Test func canonicallyEquivalentTextIsNotTheTextThatWasTyped() async throws {
    let page = ScriptedPage(scriptResults: [spot, true, caret("", 0), "e\u{301}"])
    let outcome = try await Dispatch.type(
      ref: 2, text: "\u{e9}", channel: page.channel, admit: admitAll)
    #expect(!outcome.verified)
  }

  @Test func aSelectionIsReplacedByTheTypedText() async throws {
    let page = ScriptedPage(scriptResults: [spot, true, caret("abcd", 1, 3), "aXd"])
    let outcome = try await Dispatch.type(
      ref: 2, text: "X", channel: page.channel, admit: admitAll)
    #expect(outcome.verified)
  }

  @Test func anElementThatCannotTakeTextIsNotTypedInto() async {
    let page = ScriptedPage(scriptResults: [spotWith(["editable": false])])
    await #expect(
      throws: Dispatch.Failure(message: "not an editable element", effectPossible: false)
    ) {
      try await Dispatch.type(ref: 2, text: "x", channel: page.channel, admit: admitAll)
    }
    #expect(page.writes.isEmpty)
  }
}

struct TargetResolutionTests {
  private func observation() -> Observation {
    func element(_ ref: Int, _ role: String, interactive: Bool = true) -> Element {
      Element(
        ref: ref, role: role, name: "n", bounds: Rect(x: 0, y: 0, w: 1, h: 1),
        interactive: interactive, sensitive: false)
    }
    return Observation(
      id: "o1", tabId: "t1", epoch: 0, documentKey: "F:L", viewportKey: "v", url: "", title: "",
      elements: [
        element(1, "button"), element(2, "textbox"), element(3, "button", interactive: false),
      ])
  }

  @Test func aVisibleInteractiveElementIsAValidTarget() throws {
    #expect(try observation().target(ref: 1, for: .click).ref == 1)
    #expect(try observation().target(ref: 2, for: .type).ref == 2)
  }

  @Test func unknownDisabledAndNonTextTargetsAreRefusedWithAReason() {
    let observed = observation()
    #expect(throws: ActionRejection.unknownRef) { try observed.target(ref: 99, for: .click) }
    #expect(throws: ActionRejection.notInteractive) { try observed.target(ref: 3, for: .click) }
    #expect(throws: ActionRejection.notEditable) { try observed.target(ref: 1, for: .type) }
  }
}

@MainActor
struct DispatchKindsTests {
  private let admitAll: Dispatch.Admit = { _ in nil }
  private let selected: JSON = ["ok": true, "value": "b"]

  private func keys(_ page: ScriptedPage) -> [JSON] {
    page.written.filter { $0.method == "Input.dispatchKeyEvent" }.map(\.params)
  }

  @Test func settlingFollowsTheWriteAndPrecedesTheReadBack() async throws {
    let page = ScriptedPage(scriptResults: [spot, true, caret("", 0), "hello"])
    var atSettle: [String] = []
    _ = try await Dispatch.type(
      ref: 2, text: "hello", channel: page.channel, admit: admitAll,
      settle: { atSettle = page.written.map(\.method) })
    #expect(atSettle.filter { !$0.hasPrefix("Emulation.") }.last == "Input.insertText")
    #expect(page.written.last?.method == "Runtime.releaseObject")
  }

  @Test func selectSetsTheOptionByValueInTheIsolatedWorldAndReadsItBack() async throws {
    let page = ScriptedPage(scriptResults: [selected, "b"])
    let outcome = try await Dispatch.select(
      ref: 4, value: "b", channel: page.channel, admit: admitAll)
    #expect(outcome.verified == true && outcome.verdict == "value-matches")
    let call = try #require(page.written.first { $0.method == "Runtime.callFunctionOn" })
    #expect(call.params["arguments"]?.array?.first?["value"] == "b")
    #expect(
      page.written.contains {
        $0.method == "DOM.resolveNode" && $0.params["executionContextId"] == 7
      })
  }

  @Test func selectingAMissingOptionChangesNothingAndFails() async {
    let page = ScriptedPage(scriptResults: [["ok": false, "reason": "no-such-option"]])
    await #expect(throws: Dispatch.Failure(message: "no-such-option", effectPossible: false)) {
      try await Dispatch.select(ref: 4, value: "zzz", channel: page.channel, admit: admitAll)
    }
  }

  @Test func aSelectionTheReadBackContradictsIsNotVerified() async throws {
    let page = ScriptedPage(scriptResults: [selected, "a"])
    let outcome = try await Dispatch.select(
      ref: 4, value: "b", channel: page.channel, admit: admitAll)
    #expect(outcome.verified == false && outcome.verdict == "value-mismatch")
  }

  @Test func aStaleSelectReachesNeitherTheScriptNorThePage() async {
    let page = ScriptedPage(scriptResults: [selected])
    await #expect(throws: Dispatch.Stale(reason: .epoch)) {
      try await Dispatch.select(ref: 4, value: "b", channel: page.channel) { _ in .epoch }
    }
    #expect(!page.written.contains { $0.method == "Runtime.callFunctionOn" })
  }

  @Test func pressingEnterInAFieldFocusesItThenSendsTheKeyWithItsText() async throws {
    let page = ScriptedPage(scriptResults: [spot, still, true, moved])
    let enter = try #require(PressKey.parse("Enter"))
    let outcome = try await Dispatch.press(
      enter, ref: 2, channel: page.channel, admit: admitAll)
    #expect(outcome.verified)
    #expect(page.writes == ["DOM.focus", "Input.dispatchKeyEvent", "Input.dispatchKeyEvent"])
    let sent = keys(page)
    #expect(sent.map { $0["type"]?.string } == ["keyDown", "keyUp"])
    #expect(sent[0]["key"] == "Enter" && sent[0]["text"] == "\r")
    #expect(sent[0]["windowsVirtualKeyCode"] == 13)
  }

  @Test func aKeyWithoutTextIsARawKeyDownAndGoesToWhateverHasFocus() async throws {
    let page = ScriptedPage(scriptResults: [still, moved])
    let tab = try #require(PressKey.parse("Tab"))
    _ = try await Dispatch.press(tab, ref: nil, channel: page.channel, admit: admitAll)
    #expect(page.writes == ["Input.dispatchKeyEvent", "Input.dispatchKeyEvent"])
    #expect(keys(page).map { $0["type"]?.string } == ["rawKeyDown", "keyUp"])
    #expect(keys(page)[0]["text"] == nil)
  }

  @Test func pressingIntoAFieldThatLostFocusSendsNoKey() async throws {
    let page = ScriptedPage(scriptResults: [spot, still, false])
    let enter = try #require(PressKey.parse("Enter"))
    await #expect(
      throws: Dispatch.Failure(message: Dispatch.focusRedirected, effectPossible: false)
    ) {
      try await Dispatch.press(enter, ref: 2, channel: page.channel, admit: admitAll)
    }
    #expect(keys(page).isEmpty)
  }

  @Test func scrollingDownWheelsAtTheViewportCenterAndVerifiesThePositionMoved() async throws {
    let page = ScriptedPage(scriptResults: [])
    page.evaluations = [[1100, 720, 0], 576]
    let outcome = try await Dispatch.scroll(
      direction: .down, amount: nil, channel: page.channel, admit: admitAll)
    #expect(outcome.verified == true && outcome.verdict == "scrolled")
    let wheel = try #require(page.written.first { $0.method == "Input.dispatchMouseEvent" }).params
    #expect(wheel["type"] == "mouseWheel" && wheel["x"] == 550 && wheel["y"] == 360)
    #expect(wheel["deltaY"] == 576 && wheel["deltaX"] == 0)
  }

  @Test func scrollingUpUsesANegativeDeltaAndAFixedAmount() async throws {
    let page = ScriptedPage(scriptResults: [])
    page.evaluations = [[1100, 720, 900], 700]
    let outcome = try await Dispatch.scroll(
      direction: .up, amount: 200, channel: page.channel, admit: admitAll)
    #expect(outcome.verified)
    let wheel = try #require(page.written.first { $0.method == "Input.dispatchMouseEvent" }).params
    #expect(wheel["deltaY"] == -200)
  }

  @Test func aScrollThatMovedNothingIsNotVerified() async throws {
    let page = ScriptedPage(scriptResults: [])
    page.evaluations = [[1100, 720, 0], 0]
    let outcome = try await Dispatch.scroll(
      direction: .down, amount: nil, channel: page.channel, admit: admitAll)
    #expect(outcome.verified == false && outcome.verdict == "scroll-unchanged")
  }

  @Test func navigatingVerifiesANewDocument() async throws {
    let page = ScriptedPage(scriptResults: [])
    page.loaders = ["L1", "L1", "L2"]
    let outcome = try await Dispatch.navigate(
      url: "http://127.0.0.1:47810/b.html", channel: page.channel, admit: admitAll)
    #expect(outcome.verified == true && outcome.verdict == "document-changed")
    let sent = try #require(page.written.first { $0.method == "Page.navigate" }).params
    #expect(sent["url"] == "http://127.0.0.1:47810/b.html")
  }

  @Test func aNavigationThatLeavesTheDocumentAloneIsNotVerified() async throws {
    let page = ScriptedPage(scriptResults: [])
    let outcome = try await Dispatch.navigate(
      url: "http://127.0.0.1:47810/b.html", channel: page.channel, admit: admitAll)
    #expect(outcome.verified == false && outcome.verdict == "document-unchanged")
  }

  @Test func aRefusedNavigationNamesTheError() async {
    let page = ScriptedPage(scriptResults: [])
    page.navigateReply = #"{"frameId":"F","errorText":"net::ERR_NAME_NOT_RESOLVED"}"#
    await #expect(
      throws: Dispatch.Failure(message: "net::ERR_NAME_NOT_RESOLVED", effectPossible: false)
    ) {
      try await Dispatch.navigate(
        url: "http://nowhere.invalid/", channel: page.channel, admit: admitAll)
    }
  }

  @Test func onlyHttpAndHttpsWithAHostAreWebAddresses() {
    for url in [
      "file:///etc/hosts", "FILE:///etc/hosts", "data:text/html,<p>local secret</p>",
      "javascript:alert(1)", "about:blank", "chrome://version/", "http:///no-host", "",
    ] {
      #expect(!Dispatch.isWebAddress(url), "\(url)")
    }
    for url in ["http://127.0.0.1:47810/act.html", "https://example.com/", "HTTPS://Example.com"] {
      #expect(Dispatch.isWebAddress(url), "\(url)")
    }
  }

  @Test func onlyWebAddressesAreNavigatedTo() async {
    let page = ScriptedPage(scriptResults: [])
    for url in ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings", "not a url"] {
      await #expect(throws: Dispatch.Failure.self) {
        try await Dispatch.navigate(url: url, channel: page.channel, admit: admitAll)
      }
    }
    #expect(!page.written.contains { $0.method == "Page.navigate" })
  }

  @Test func aStaleNavigationSendsNothing() async {
    let page = ScriptedPage(scriptResults: [])
    await #expect(throws: Dispatch.Stale(reason: .notInControl)) {
      try await Dispatch.navigate(url: "http://127.0.0.1:47810/b.html", channel: page.channel) {
        _ in .notInControl
      }
    }
    #expect(!page.written.contains { $0.method == "Page.navigate" })
  }
}
