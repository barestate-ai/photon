import Foundation

/// Marks elements whose use needs a human's Allow once (architecture §5.6).
public enum Sensitivity {
  public static func isSensitive(name: String, inputType: String?, isSubmit: Bool) -> Bool {
    if inputType == "password" || isSubmit { return true }
    return name.contains(
      /\b(pay|buy|purchase|checkout|order|send|delete|remove|transfer)\b/.ignoresCase())
  }
}

/// What a control is, read from the page now rather than from an observation that may be old: the
/// page can rename a button or retype an input without changing its document or viewport key.
public struct LiveTarget: Equatable, Sendable {
  public let tag: String
  public let inputType: String?
  public let isSubmit: Bool
  /// Every word that could name the control, so a keyword in any of them counts.
  public let words: String
  /// The one a person would call it.
  public let label: String
  /// What Enter in this control submits (the form's default button, or the form itself when it is
  /// the only field that blocks implicit submission); nil when Enter submits nothing.
  public let submitsVia: String?
  /// The backend node id. Two controls with the same words are still two controls.
  public let node: Int
  /// A frame, or the host of a closed shadow root: what it holds cannot be read from here, so a
  /// write it receives is treated as sensitive.
  public let opaque: Bool

  public var isSensitive: Bool {
    Sensitivity.isSensitive(name: words, inputType: inputType, isSubmit: isSubmit)
  }

  /// A submit is sensitive however it is reached, so Enter in a field is as sensitive as a click on
  /// the button it triggers. Into an opaque target a click, text, or a key that enters text (a
  /// character, Space, Enter) could reach any control or a password field; navigation and editing
  /// keys (arrows, Tab, Escape, Backspace) change nothing the page cannot undo.
  public func isSensitive(pressing key: PressKey?) -> Bool {
    isSensitive || submitting(on: key) != nil || (opaque && key.map { $0.text != nil } ?? true)
  }

  public func submitting(on key: PressKey?) -> String? {
    key?.key == "Enter" ? submitsVia : nil
  }

  init?(json: JSON, node: Int, closedShadow: Bool) {
    guard let tag = json["tag"]?.string, let words = json["words"]?.string,
      let label = json["label"]?.string
    else { return nil }
    self.init(
      tag: tag, inputType: json["type"]?.string, isSubmit: json["submit"]?.bool ?? false,
      words: words, label: label, submitsVia: json["via"]?.string, node: node,
      opaque: json["frame"]?.bool == true || closedShadow)
  }

  public init(
    tag: String, inputType: String?, isSubmit: Bool, words: String, label: String,
    submitsVia: String? = nil, node: Int = 0, opaque: Bool = false
  ) {
    self.tag = tag
    self.inputType = inputType
    self.isSubmit = isSubmit
    self.words = words
    self.label = opaque && label.isEmpty ? "an embedded frame" : label
    self.submitsVia = submitsVia
    self.node = node
    self.opaque = opaque
  }

  /// Runs with `this` bound to the element.
  static let script = #"""
    function () {
      if (!this || this.nodeType !== 1) return null;
      const frames = ["iframe", "frame", "object", "embed"];
      const names = (el) => {
        const doc = el.ownerDocument, tag = el.tagName.toLowerCase();
        const attr = (el.getAttribute("type") || "").toLowerCase();
        const named = (el.getAttribute("aria-labelledby") || "").split(/\s+/)
          .map((id) => (doc.getElementById(id) || {}).textContent || "");
        const labels = Array.from(el.labels || []).map((l) => l.textContent);
        const buttonLike = tag === "button" || (tag === "input" && ["button", "submit", "reset", "image"].includes(attr));
        return [el.getAttribute("aria-label"), ...named, ...labels,
          buttonLike ? el.value : null, frames.includes(tag) ? null : el.textContent, el.title, el.getAttribute("placeholder")]
          .map((text) => (text || "").trim().replace(/\s+/g, " ")).filter(Boolean);
      };
      const el = this, tag = el.tagName.toLowerCase();
      const attr = (el.getAttribute("type") || "").toLowerCase();
      const candidates = names(el);
      const submit = tag === "button"
        ? attr === "submit" || (!["reset", "button"].includes(attr) && !!el.form)
        : tag === "input" && (attr === "submit" || attr === "image");
      // HTML's implicit submission: Enter in a field presses the form's first submit button, or
      // submits the form itself when no more than one field could stand in for it.
      let via = null;
      const form = el.form;
      if (form && tag === "input" && !["button", "submit", "reset", "image"].includes(attr)) {
        const button = Array.from(el.getRootNode().querySelectorAll("button, input")).find((b) =>
          b.form === form && (b.type === "submit" || (b.tagName === "INPUT" && b.type === "image")));
        const blocking = new Set(["text", "search", "url", "tel", "email", "password", "date",
          "month", "week", "time", "datetime-local", "number"]);
        const fields = Array.from(form.elements).filter((f) => f.tagName === "INPUT" && blocking.has(f.type));
        if (button ? !button.disabled : fields.length <= 1) {
          via = button ? (names(button)[0] || "Submit").slice(0, 80) : "the form";
        }
      }
      return {
        tag, type: tag === "input" ? (attr || "text") : null, submit, via,
        frame: frames.includes(tag),
        words: candidates.join(" ").slice(0, 1000), label: (candidates[0] || "").slice(0, 80),
      };
    }
    """#

  /// The control behind `ref`, or the focused control when there is none. `nil` when the page cannot
  /// be read or nothing is there: callers that gate on it treat that as sensitive.
  public static func read(ref: Int?, transport: any CDPTransport) async -> LiveTarget? {
    do {
      if let ref {
        let reply = try await Extractor.callOnNode(transport, ref: ref, function: script)
        let described = try await transport.send(
          "DOM.describeNode", ["backendNodeId": .number(Double(ref)), "depth": 0])
        return LiveTarget(json: reply, node: ref, closedShadow: hasClosedShadow(described))
      }
      return try await readFocused(transport)
    } catch {
      return nil
    }
  }

  private static func hasClosedShadow(_ described: JSON) -> Bool {
    described["node"]?["shadowRoots"]?.array?.contains { $0["shadowRootType"]?.string == "closed" }
      ?? false
  }

  /// The deepest focused element: `document.activeElement` is only the host of an open shadow root.
  private static let focusedElement = """
    (() => { let a = document.activeElement;
      while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
      return a; })()
    """

  private static func readFocused(_ transport: any CDPTransport) async throws -> LiveTarget? {
    let context = try await Extractor.isolatedContext(transport)
    let active = try await transport.send(
      "Runtime.evaluate",
      ["contextId": .number(Double(context)), "expression": .string(Self.focusedElement)])
    guard let objectId = active["result"]?["objectId"]?.string else { return nil }
    return try await Extractor.holding(objectId, transport) { objectId in
      let call = Extractor.call(objectId: objectId, function: script)
      let reply = try Extractor.value(of: try await transport.send(call.method, call.params))
      let described = try await transport.send("DOM.describeNode", ["objectId": .string(objectId)])
      guard let node = described["node"]?["backendNodeId"]?.int else { return nil }
      return LiveTarget(json: reply, node: node, closedShadow: hasClosedShadow(described))
    }
  }
}
