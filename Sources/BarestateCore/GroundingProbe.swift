import Foundation

/// The viewport as a picture, plus the sizes needed to turn a point in the picture back into CSS
/// pixels. No `clip` is set: that would make Chromium resize the page for the copy.
public struct Screenshot: Sendable {
  public let png: Data
  public let pixelWidth: Double
  public let pixelHeight: Double
  public let cssWidth: Double
  public let cssHeight: Double

  public func css(fromPixel x: Double, _ y: Double) -> Point {
    Point(x: x * cssWidth / pixelWidth, y: y * cssHeight / pixelHeight)
  }

  public static func capture(_ transport: any CDPTransport) async throws -> Screenshot {
    async let metrics = transport.send("Page.getLayoutMetrics", [:])
    async let shot = transport.send(
      "Page.captureScreenshot", ["format": "png", "fromSurface": true])
    let layout = try await metrics["cssLayoutViewport"]
    guard let width = layout?["clientWidth"]?.number, let height = layout?["clientHeight"]?.number,
      let encoded = try await shot["data"]?.string, let png = Data(base64Encoded: encoded),
      let size = pngSize(png)
    else { throw CDPError.remote(code: -32000, message: "no screenshot of the viewport") }
    return Screenshot(
      png: png, pixelWidth: size.width, pixelHeight: size.height, cssWidth: width, cssHeight: height
    )
  }

  /// Width and height from the IHDR chunk.
  static func pngSize(_ png: Data) -> (width: Double, height: Double)? {
    let bytes = [UInt8](png.prefix(24))
    guard bytes.count == 24, bytes[1...3] == [0x50, 0x4E, 0x47] else { return nil }
    func word(_ at: Int) -> Double {
      Double(bytes[at...at + 3].reduce(0) { $0 << 8 | UInt32($1) })
    }
    return (word(16), word(20))
  }
}

/// What is under a point on the page (architecture §5.4): the topmost node, its nearest
/// interactive ancestor, whether that ancestor can be seen, and the words it shows.
public enum PointProbe {
  public static func candidate(x: Double, y: Double, transport: any CDPTransport) async throws
    -> PointCandidate
  {
    let hit: JSON
    do {
      hit = try await transport.send(
        "DOM.getNodeForLocation",
        ["x": .number(x.rounded()), "y": .number(y.rounded()), "includeUserAgentShadowDOM": false])
    } catch CDPError.remote(_, _) {
      return PointCandidate(ref: nil, visible: false, fields: [])
    }
    guard let node = hit["backendNodeId"]?.int else {
      return PointCandidate(ref: nil, visible: false, fields: [])
    }
    return try await Extractor.withNode(transport, ref: node) { objectId in
      let found = try await transport.send(
        "Runtime.callFunctionOn",
        ["objectId": .string(objectId), "functionDeclaration": .string(ancestorScript)])
      guard let ancestor = found["result"]?["objectId"]?.string else {
        return PointCandidate(ref: nil, visible: false, fields: [])
      }
      let release = {
        _ = try? await transport.send("Runtime.releaseObject", ["objectId": .string(ancestor)])
      }
      do {
        let described = try await transport.send(
          "DOM.describeNode", ["objectId": .string(ancestor)])
        let request = Extractor.call(objectId: ancestor, function: infoScript)
        let info = try Extractor.value(of: try await transport.send(request.method, request.params))
        await release()
        return PointCandidate(
          ref: described["node"]?["backendNodeId"]?.int, visible: info["visible"]?.bool == true,
          fields: info["fields"]?.array?.compactMap(\.string) ?? [])
      } catch {
        await release()
        throw error
      }
    }
  }

  /// The name and value the accessibility tree gives the element behind `ref` right now: the
  /// words an observation would list for it.
  public static func words(ref: Int, transport: any CDPTransport) async throws -> [String] {
    let reply = try await transport.send(
      "Accessibility.getPartialAXTree",
      ["backendNodeId": .number(Double(ref)), "fetchRelatives": false])
    let node = reply["nodes"]?.array?.first { $0["backendDOMNodeId"]?.int == ref }
    return ["name", "value"].compactMap { node?[$0]?["value"]?.string }
  }

  private static let ancestorScript = #"""
    function () {
      const roles = new Set(["button", "link", "checkbox", "radio", "switch", "tab", "menuitem",
        "menuitemcheckbox", "menuitemradio", "option", "combobox", "textbox", "searchbox",
        "slider", "spinbutton", "treeitem"]);
      const interactive = (el) => {
        const tag = el.tagName;
        if (tag === "A") return el.hasAttribute("href");
        if (["BUTTON", "SELECT", "TEXTAREA", "SUMMARY"].includes(tag)) return !el.disabled;
        if (tag === "INPUT") return el.type !== "hidden" && !el.disabled;
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) {
          return true;
        }
        if (roles.has(el.getAttribute("role"))) return true;
        return el.hasAttribute("onclick") || (el.hasAttribute("tabindex") && el.tabIndex >= 0);
      };
      let node = this.nodeType === 1 ? this : this.parentElement;
      while (node) {
        if (interactive(node)) return node;
        const root = node.getRootNode();
        node = node.parentElement || (root instanceof ShadowRoot ? root.host : null);
      }
      return null;
    }
    """#

  private static let infoScript = #"""
    function () {
      const box = this.getBoundingClientRect();
      let visible = box.width > 0 && box.height > 0 && getComputedStyle(this).visibility === "visible";
      let opacity = 1;
      for (let n = this; n; ) {
        const style = getComputedStyle(n);
        if (style.display === "none") visible = false;
        opacity *= Number(style.opacity);
        const root = n.getRootNode();
        n = n.parentElement || (root instanceof ShadowRoot ? root.host : null);
      }
      if (opacity < 0.05) visible = false;
      const fields = [this.getAttribute("aria-label"), this.innerText || this.textContent,
        this.title, this.placeholder, this.alt];
      if (this.tagName === "INPUT" && ["button", "submit", "reset"].includes(this.type)) {
        fields.push(this.value);
      }
      for (const label of this.labels || []) fields.push(label.textContent);
      return {
        visible,
        fields: fields.filter((f) => typeof f === "string" && f.trim()).map((f) => f.trim().slice(0, 200)),
      };
    }
    """#
}

/// Safety checks the provider attached to a click. They are acknowledged once, by the caller,
/// after the permission layer has allowed the click.
public struct SafetyAck: Sendable {
  public let responseId: String
  public let callId: String
  public let checks: [JSON]

  public init(responseId: String, callId: String, checks: [JSON]) {
    self.responseId = responseId
    self.callId = callId
    self.checks = checks
  }
}

/// Muse's computer tool as a last grounding rung: a screenshot and the instruction go in, one
/// click point comes out. Nothing is executed here; the point still has to pass acceptance.
public struct MuseGrounder: Sendable {
  public static let instructions =
    "You control a web browser through screenshots. Click the one element that carries out the "
    + "user's instruction. If you cannot find it, do not click."

  /// The model reasons before it answers, and an answer cut off at the default 400 tokens has no
  /// click in it.
  private static let maxOutputTokens = 1000

  public let model: ModelClient

  public init(model: ModelClient) { self.model = model }

  /// A click in the pixels of the screenshot the model was given, from one `computer_call`.
  public static func click(in call: JSON) -> (x: Double, y: Double)? {
    for action in call["actions"]?.array ?? [] {
      guard let type = action["type"]?.string, ["click", "double_click"].contains(type),
        let x = action["x"]?.number, let y = action["y"]?.number
      else { continue }
      return (x, y)
    }
    return nil
  }

  private static func dataURL(_ png: Data) -> String {
    "data:image/png;base64," + png.base64EncodedString()
  }

  private func reply(
    _ callId: String, _ shot: Screenshot, checks: [JSON], after previous: String?
  ) -> ModelRequest {
    var output: [String: JSON] = [
      "type": "computer_call_output", "call_id": .string(callId),
      "output": ["type": "computer_screenshot", "image_url": .string(Self.dataURL(shot.png))],
    ]
    if !checks.isEmpty { output["acknowledged_safety_checks"] = .array(checks) }
    return ModelRequest(
      instructions: Self.instructions, input: [.object(output)], computer: true,
      previousResponseId: previous, maxOutputTokens: Self.maxOutputTokens)
  }

  /// Turn one often answers with a bare `screenshot` action; it is answered, then the click
  /// arrives. A click carrying safety checks is handed to `onChecks` unanswered.
  @MainActor
  public func ground(
    _ instruction: String, transport: any CDPTransport, onChecks: ((SafetyAck) -> Void)? = nil
  ) async throws -> Point? {
    var shot = try await Screenshot.capture(transport)
    let size = "\(Int(shot.pixelWidth))x\(Int(shot.pixelHeight))"
    var response = try await model.call(
      ModelRequest(
        instructions: Self.instructions,
        input: [
          [
            "role": "user",
            "content": [
              ["type": "input_text", "text": .string("The screen is \(size). \(instruction)")],
              ["type": "input_image", "image_url": .string(Self.dataURL(shot.png))],
            ],
          ]
        ], computer: true, maxOutputTokens: Self.maxOutputTokens),
      source: "ground")
    for turn in 1...3 {
      guard let call = response.computerCall else { return nil }
      let checks = call["pending_safety_checks"]?.array ?? []
      if let click = Self.click(in: call) {
        if !checks.isEmpty, let callId = call["call_id"]?.string {
          onChecks?(SafetyAck(responseId: response.id, callId: callId, checks: checks))
        }
        return shot.css(fromPixel: click.x, click.y)
      }
      guard turn < 3,
        call["actions"]?.array?.contains(where: { $0["type"] == "screenshot" }) == true,
        let callId = call["call_id"]?.string
      else { return nil }
      shot = try await Screenshot.capture(transport)
      response = try await model.call(
        reply(callId, shot, checks: checks, after: response.id), source: "ground")
    }
    return nil
  }

  /// Answers the click's `computer_call` with its checks, once.
  @MainActor
  public func acknowledge(_ ack: SafetyAck, transport: any CDPTransport) async throws {
    let shot = try await Screenshot.capture(transport)
    _ = try await model.call(
      reply(ack.callId, shot, checks: ack.checks, after: ack.responseId), source: "ack")
  }
}
