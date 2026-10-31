import BarestateCore
import Foundation
import Testing

/// A page behind a real `CDPChannel` whose answers come from a closure, so each test says what
/// the browser would return for the one method it cares about.
@MainActor
private final class Page {
  var written: [(method: String, params: JSON)] = []
  private let answer: (String, JSON) -> String
  private(set) var channel: CDPChannel!

  init(_ answer: @escaping (String, JSON) -> String) {
    self.answer = answer
    channel = CDPChannel { [weak self] text in self?.reply(text) ?? false }
  }

  private func reply(_ text: String) -> Bool {
    guard let message = JSON.parse(Data(text.utf8)), let id = message["id"]?.int,
      let method = message["method"]?.string
    else { return false }
    let params = message["params"] ?? .null
    written.append((method, params))
    let body = answer(method, params)
    if body.hasPrefix("error:") {
      channel.receive(
        Data(#"{"id":\#(id),"error":{"code":-32000,"message":"\#(body.dropFirst(6))"}}"#.utf8))
    } else {
      channel.receive(Data(#"{"id":\#(id),"result":\#(body)}"#.utf8))
    }
    return true
  }
}

private func basics(_ method: String) -> String? {
  switch method {
  case "Page.getFrameTree": #"{"frameTree":{"frame":{"id":"F","loaderId":"L1"}}}"#
  case "Page.createIsolatedWorld": #"{"executionContextId":7}"#
  case "DOM.resolveNode": #"{"object":{"objectId":"hit"}}"#
  default: nil
  }
}

@MainActor
struct ProbeTests {
  private func probe(_ page: Page) async throws -> PointCandidate {
    try await PointProbe.candidate(x: 120.4, y: 79.6, transport: page.channel)
  }

  @Test func theNearestInteractiveAncestorIsNamedByItsRefWithItsVisibilityAndWords() async throws {
    let page = Page { method, params in
      if let fixed = basics(method) { return fixed }
      switch method {
      case "DOM.getNodeForLocation": return #"{"backendNodeId":5}"#
      case "DOM.describeNode": return #"{"node":{"backendNodeId":9}}"#
      case "Runtime.callFunctionOn" where params["objectId"] == "hit":
        return #"{"result":{"type":"object","objectId":"anc"}}"#
      case "Runtime.callFunctionOn":
        return #"{"result":{"value":{"visible":true,"fields":["Save","Save draft"]}}}"#
      default: return "{}"
      }
    }
    let candidate = try await probe(page)
    #expect(candidate == PointCandidate(ref: 9, visible: true, fields: ["Save", "Save draft"]))
    let asked = try #require(page.written.first { $0.method == "DOM.getNodeForLocation" }).params
    #expect(asked["x"] == 120 && asked["y"] == 80)
    #expect(page.written.filter { $0.method == "Runtime.releaseObject" }.count == 2)
  }

  @Test func theNameAndValueAnElementHasNowComeFromItsAccessibilityNodeAndAGoneElementThrows()
    async throws
  {
    let page = Page { method, params in
      if method == "Accessibility.getPartialAXTree" && params["backendNodeId"] == 404 {
        return "error:No node with given id found"
      }
      if let fixed = basics(method) { return fixed }
      switch method {
      case "Accessibility.getPartialAXTree":
        return
          #"{"nodes":[{"backendDOMNodeId":9,"name":{"value":"Cancel"},"value":{"value":"now"}}]}"#
      default: return "{}"
      }
    }
    #expect(try await PointProbe.words(ref: 9, transport: page.channel) == ["Cancel", "now"])
    #expect(try await PointProbe.words(ref: 10, transport: page.channel) == [])
    await #expect(throws: CDPError.self) {
      try await PointProbe.words(ref: 404, transport: page.channel)
    }
  }

  @Test func aPointWithNoInteractiveAncestorHasNoRef() async throws {
    let page = Page { method, _ in
      if let fixed = basics(method) { return fixed }
      switch method {
      case "DOM.getNodeForLocation": return #"{"backendNodeId":5}"#
      case "Runtime.callFunctionOn":
        return #"{"result":{"type":"object","subtype":"null","value":null}}"#
      default: return "{}"
      }
    }
    let candidate = try await probe(page)
    #expect(candidate == PointCandidate(ref: nil, visible: false, fields: []))
  }

  @Test func aPointThatHitsNothingHasNoRef() async throws {
    let page = Page { method, _ in
      method == "DOM.getNodeForLocation" ? "error:No node found at given location" : "{}"
    }
    let candidate = try await probe(page)
    #expect(candidate.ref == nil)
  }

  @Test func theScreenshotKnowsItsPixelAndCssSizeSoAPointMapsBack() async throws {
    var header = Data([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
    ])
    header.append(contentsOf: [0, 0, 0x08, 0x98, 0, 0, 0x05, 0xA0])
    let page = Page { method, _ in
      switch method {
      case "Page.getLayoutMetrics":
        #"{"cssLayoutViewport":{"clientWidth":1100,"clientHeight":720}}"#
      case "Page.captureScreenshot": #"{"data":"\#(header.base64EncodedString())"}"#
      default: "{}"
      }
    }
    let shot = try await Screenshot.capture(page.channel)
    #expect(shot.pixelWidth == 2200 && shot.pixelHeight == 1440)
    #expect(shot.css(fromPixel: 1100, 720) == Point(x: 550, y: 360))
    let asked = try #require(page.written.first { $0.method == "Page.captureScreenshot" }).params
    #expect(asked["clip"] == nil && asked["format"] == "png")
  }

  @Test func aScreenshotThatIsNotAPngIsRefused() async {
    let page = Page { method, _ in
      method == "Page.getLayoutMetrics"
        ? #"{"cssLayoutViewport":{"clientWidth":10,"clientHeight":10}}"#
        : #"{"data":"AAAA"}"#
    }
    await #expect(throws: CDPError.self) { try await Screenshot.capture(page.channel) }
  }
}

struct MuseClickTests {
  @Test func theFirstClickInACallIsReadInScreenshotPixels() {
    let call: JSON = [
      "actions": [["type": "screenshot"], ["type": "click", "x": 159, "y": 105]]
    ]
    let click = MuseGrounder.click(in: call)
    #expect(click?.x == 159 && click?.y == 105)
  }

  @Test func aBareScreenshotOrATypeActionIsNotAClick() {
    #expect(MuseGrounder.click(in: ["actions": [["type": "screenshot"]]]) == nil)
    #expect(MuseGrounder.click(in: ["actions": [["type": "type", "text": "x"]]]) == nil)
    #expect(MuseGrounder.click(in: ["actions": [["type": "click"]]]) == nil)
  }
}

private final class Wire: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [String]
  private(set) var bodies: [JSON] = []

  init(_ replies: [String]) { queue = replies }

  var transport: ModelTransport {
    { [self] request, _ in
      let body = lock.withLock { () -> String in
        bodies.append(JSON.parse(request.httpBody ?? Data()) ?? .null)
        return queue.removeFirst()
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(body.utf8), response)
    }
  }
}

private let safetyCheck =
  #"{"id":"cu_sc_1","code":"computer_action_requires_confirmation","message":"Review"}"#

private func turn(_ id: String, _ actions: String, checks: String = "[]") -> String {
  """
  {"id":"\(id)","model":"muse-spark-1.3","output":[{"type":"computer_call","call_id":"call_\(id)",
  "actions":\(actions),"pending_safety_checks":\(checks)}],
  "usage":{"input_tokens":10,"output_tokens":5}}
  """
}

@MainActor
struct MuseGroundingTests {
  private func page() -> Page {
    var header = Data([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
    ])
    header.append(contentsOf: [0, 0, 0x03, 0x20, 0, 0, 0x02, 0x58])  // 800 x 600
    return Page { method, _ in
      switch method {
      case "Page.getLayoutMetrics":
        #"{"cssLayoutViewport":{"clientWidth":400,"clientHeight":300}}"#
      case "Page.captureScreenshot": #"{"data":"\#(header.base64EncodedString())"}"#
      default: "{}"
      }
    }
  }

  private func grounder(_ wire: Wire) -> MuseGrounder {
    MuseGrounder(
      model: ModelClient(
        environment: ["MODEL_API_KEY": "sk-test"], envFile: nil,
        ledger: SpendLedger(path: NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"),
        transport: wire.transport))
  }

  @Test func aBareScreenshotTurnIsAnsweredThenTheClickIsMappedToCssPixels() async throws {
    let wire = Wire([
      turn("r1", #"[{"type":"screenshot"}]"#), turn("r2", #"[{"type":"click","x":400,"y":150}]"#),
    ])
    let page = page()
    defer { withExtendedLifetime(page) {} }
    let point = try await grounder(wire).ground("click save", transport: page.channel)
    #expect(point == Point(x: 200, y: 75))
    #expect(wire.bodies.count == 2)
    let first = wire.bodies[0]
    #expect(first["tools"]?.array?.first?["type"] == "computer")
    let text = first["input"]?.array?.first?["content"]?.array?.first?["text"]?.string
    #expect(text == "The screen is 800x600. click save")
    let second = wire.bodies[1]
    #expect(second["previous_response_id"] == "r1")
    let output = second["input"]?.array?.first
    #expect(output?["type"] == "computer_call_output" && output?["call_id"] == "call_r1")
    #expect(output?["acknowledged_safety_checks"] == nil)
  }

  @Test func aModelThatNeverClicksYieldsNoPointAfterAtMostThreeTurns() async throws {
    let wire = Wire((1...3).map { turn("r\($0)", #"[{"type":"screenshot"}]"#) })
    let page = page()
    defer { withExtendedLifetime(page) {} }
    let point = try await grounder(wire).ground("click save", transport: page.channel)
    #expect(point == nil)
    #expect(wire.bodies.count == 3)
  }

  @Test func aClickWithPendingChecksIsHandedBackUnacknowledgedForTheCallerToSendAfterPermission()
    async throws
  {
    let wire = Wire([turn("r1", #"[{"type":"click","x":40,"y":20}]"#, checks: "[\(safetyCheck)]")])
    var seen: SafetyAck?
    let page = page()
    defer { withExtendedLifetime(page) {} }
    let point = try await grounder(wire).ground(
      "click save", transport: page.channel, onChecks: { seen = $0 })
    #expect(point != nil)
    #expect(wire.bodies.count == 1)
    #expect(seen?.callId == "call_r1" && seen?.responseId == "r1")
    #expect(seen?.checks.count == 1)
  }

  @Test func acknowledgingSendsEachCheckOnceWithTheScreenshotOnTheSameConversation() async throws {
    let wire = Wire([turn("r2", #"[{"type":"screenshot"}]"#)])
    let ack = SafetyAck(
      responseId: "r1", callId: "call_r1", checks: [JSON.parse(Data(safetyCheck.utf8))!])
    let page = page()
    defer { withExtendedLifetime(page) {} }
    try await grounder(wire).acknowledge(ack, transport: page.channel)
    let body = wire.bodies[0]
    #expect(body["previous_response_id"] == "r1")
    #expect(body["tools"]?.array?.first?["type"] == "computer")
    let output = try #require(body["input"]?.array?.first)
    #expect(output["type"] == "computer_call_output" && output["call_id"] == "call_r1")
    #expect(output["acknowledged_safety_checks"]?.array?.count == 1)
    #expect(output["acknowledged_safety_checks"]?[0]?["id"] == "cu_sc_1")
    #expect(output["output"]?["type"] == "computer_screenshot")
    #expect(body.serialized().components(separatedBy: "cu_sc_1").count == 2)
  }

  @Test func aScreenshotOnlyTurnWithChecksIsAnsweredWithThemAtOnceNothingIsThereToPermit()
    async throws
  {
    let wire = Wire([
      turn("r1", #"[{"type":"screenshot"}]"#, checks: "[\(safetyCheck)]"),
      turn("r2", #"[{"type":"click","x":40,"y":20}]"#),
    ])
    var seen: SafetyAck?
    let page = page()
    defer { withExtendedLifetime(page) {} }
    _ = try await grounder(wire).ground(
      "click save", transport: page.channel, onChecks: { seen = $0 })
    let output = wire.bodies[1]["input"]?.array?.first
    #expect(output?["acknowledged_safety_checks"]?.array?.count == 1)
    #expect(seen == nil)
  }
}
