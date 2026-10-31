import Foundation

public enum ActionKind: String, Sendable {
  case click, type, select, press, scroll, navigate
}

public enum ScrollDirection: String, Sendable {
  case up, down
}

/// Why a ref in an observation cannot be acted on, before anything is dispatched.
public enum ActionRejection: String, Error, Sendable {
  case unknownRef = "unknown-ref"
  case notInteractive = "not-interactive"
  case notEditable = "not-editable"
}

extension Observation {
  private static let editableRoles: Set<String> = ["textbox", "searchbox", "spinbutton"]

  public func target(ref: Int, for kind: ActionKind) throws -> Element {
    guard let element = elements.first(where: { $0.ref == ref }) else {
      throw ActionRejection.unknownRef
    }
    guard element.interactive else { throw ActionRejection.notInteractive }
    if kind == .type && !Self.editableRoles.contains(element.role) {
      throw ActionRejection.notEditable
    }
    return element
  }
}

public struct DispatchOutcome: Sendable, Equatable {
  /// The page read-back proves the effect (`confirmed`); false means it contradicts it (`failed`).
  public let verified: Bool
  public let verdict: String

  public init(verified: Bool, verdict: String) {
    self.verified = verified
    self.verdict = verdict
  }
}

/// Delivers one action to the page (architecture §5.4). Every write is preceded by a fresh read of
/// the page's keys and a synchronous `admit` on the main actor, with no suspension between that
/// check and the write, so a human event cannot slip in after the check.
public enum Dispatch {
  public static let focusRedirected = "focus-redirected"

  /// Returns the reason an action is no longer deliverable, or nil.
  public typealias Admit = @MainActor (PageKeys) -> StaleReason?

  /// Returns once the page has finished reacting to the write that just went out.
  public typealias Settle = @MainActor () async -> Void

  /// Asked as the last await before a write; false means the control is no longer the one that was
  /// checked, and the write is refused as stale.
  public typealias Recheck = @MainActor () async -> Bool

  public struct Stale: Error, Equatable {
    public let reason: StaleReason

    public init(reason: StaleReason) { self.reason = reason }
  }

  public struct Failure: Error, Equatable {
    public let message: String
    /// True when something may already have reached the page; the action must not be retried.
    public let effectPossible: Bool

    public init(message: String, effectPossible: Bool) {
      self.message = message
      self.effectPossible = effectPossible
    }
  }

  @MainActor
  public static func click(
    ref: Int, channel: CDPChannel, admit: Admit, settle: Settle = {}, recheck: Recheck? = nil
  ) async throws -> DispatchOutcome {
    let keysBefore = try await precheck(channel, admit)
    let spot = try await locate(ref, channel)
    guard spot.onscreen else {
      throw Failure(message: "outside the viewport", effectPossible: false)
    }
    guard spot.hit else {
      throw Failure(message: "covered by another element", effectPossible: false)
    }
    let before = try await snapshotBefore(ref: ref, channel)
    func mouse(_ type: String) -> (String, JSON) {
      (
        "Input.dispatchMouseEvent",
        [
          "type": .string(type), "x": .number(spot.x), "y": .number(spot.y), "button": "left",
          "clickCount": 1,
        ]
      )
    }
    // Press and release go out together: after the admission nothing can leave the button down or
    // let a human event fall between them.
    try await write(
      [mouse("mousePressed"), mouse("mouseReleased")], channel, admit,
      beforeAdmit: { try await confirm(recheck) })
    await settle()
    return try await readBackEffect(
      ref: ref, before: before, keysBefore: keysBefore, channel)
  }

  @MainActor
  public static func type(
    ref: Int, text: String, channel: CDPChannel, admit: Admit, settle: Settle = {},
    recheck: Recheck? = nil
  ) async throws -> DispatchOutcome {
    try await precheck(channel, admit)
    let spot = try await locate(ref, channel)
    guard spot.editable else {
      throw Failure(message: "not an editable element", effectPossible: false)
    }
    var caret: ReadBack.Caret?
    try await withFocusEmulation(channel) {
      try await write(
        [("DOM.focus", ["backendNodeId": .number(Double(ref))])], channel, admit)
      try await write(
        [("Input.insertText", ["text": .string(text)])], channel, admit, landed: true,
        beforeAdmit: {
          try await requireFocus(ref, channel)
          caret = try await readCaret(ref, channel)
          try await confirm(recheck)
        })
    }
    await settle()
    let value: JSON
    do {
      value = try await Extractor.callOnNode(channel, ref: ref, function: readBack)
    } catch let error as CDPError {
      throw Failure(message: "read-back failed: \(error)", effectPossible: true)
    }
    // Swift equates canonically equivalent strings; the page's value must match unit for unit.
    let verified =
      caret.map {
        value.string?.utf16.elementsEqual(
          ReadBack.expectedValue(before: $0, inserting: text).utf16) ?? false
      } ?? false
    return DispatchOutcome(
      verified: verified, verdict: verified ? "value-matches" : "value-mismatch")
  }

  /// Sets the option in the isolated world, so no native popup opens and a page that replaced
  /// `HTMLSelectElement.prototype` never sees the call. `input` then `change`, as a user's pick does.
  @MainActor
  public static func select(
    ref: Int, value: String, channel: CDPChannel, admit: Admit, settle: Settle = {},
    recheck: Recheck? = nil
  ) async throws -> DispatchOutcome {
    try await precheck(channel, admit)
    let reply: JSON
    do {
      reply = try await Extractor.withNode(channel, ref: ref) { objectId in
        let call = Extractor.call(
          objectId: objectId, function: selectScript, arguments: [.string(value)])
        return try await write([call], channel, admit, beforeAdmit: { try await confirm(recheck) })[
          0]
      }
    } catch let error as CDPError {
      throw Failure(message: "cannot select: \(error)", effectPossible: false)
    }
    let picked = try Extractor.value(of: reply)
    guard picked["ok"]?.bool == true, let chosen = picked["value"]?.string else {
      throw Failure(message: picked["reason"]?.string ?? "select failed", effectPossible: false)
    }
    await settle()
    let now: JSON
    do {
      now = try await Extractor.callOnNode(
        channel, ref: ref, function: "function () { return this.value; }")
    } catch let error as CDPError {
      throw Failure(message: "read-back failed: \(error)", effectPossible: true)
    }
    let verified = now.string == chosen
    return DispatchOutcome(
      verified: verified, verdict: verified ? "value-matches" : "value-mismatch")
  }

  /// One key press. With a `ref` the element is focused first, as `type` does.
  @MainActor
  public static func press(
    _ key: PressKey, ref: Int?, channel: CDPChannel, admit: Admit, settle: Settle = {},
    recheck: Recheck? = nil
  ) async throws -> DispatchOutcome {
    let keysBefore = try await precheck(channel, admit)
    func event(_ type: String) -> (String, JSON) {
      var params: [String: JSON] = [
        "type": .string(type), "key": .string(key.key), "code": .string(key.code),
        "windowsVirtualKeyCode": .number(Double(key.keyCode)),
      ]
      if type == "keyDown", let text = key.text { params["text"] = .string(text) }
      return ("Input.dispatchKeyEvent", .object(params))
    }
    var landed = false
    if let ref {
      let spot = try await locate(ref, channel)
      guard spot.onscreen else {
        throw Failure(message: "outside the viewport", effectPossible: false)
      }
    }
    let before = try await snapshotBefore(ref: ref, channel)
    let down = key.text == nil ? "rawKeyDown" : "keyDown"
    try await withFocusEmulation(channel) {
      if let ref {
        try await write([("DOM.focus", ["backendNodeId": .number(Double(ref))])], channel, admit)
        landed = true
      }
      try await write(
        [event(down), event("keyUp")], channel, admit, landed: landed,
        beforeAdmit: {
          if let ref { try await requireFocus(ref, channel) }
          try await confirm(recheck)
        })
    }
    await settle()
    return try await readBackEffect(
      ref: ref, before: before, keysBefore: keysBefore, channel)
  }

  /// A mouse wheel at the viewport's center. Verified by the scroll position having moved.
  @MainActor
  public static func scroll(
    direction: ScrollDirection, amount: Double?, channel: CDPChannel, admit: Admit,
    settle: Settle = {}
  ) async throws -> DispatchOutcome {
    try await precheck(channel, admit)
    let state = try await evaluate(channel, "[innerWidth, innerHeight, scrollY]")
    guard let parts = state.array, parts.count == 3, let width = parts[0].number,
      let height = parts[1].number, let before = parts[2].number
    else { throw Failure(message: "cannot read the scroll position", effectPossible: false) }
    let distance = min(max(amount ?? height * 0.8, 1), 5000) * (direction == .down ? 1 : -1)
    try await write(
      [
        (
          "Input.dispatchMouseEvent",
          [
            "type": "mouseWheel", "x": .number(width / 2), "y": .number(height / 2),
            "deltaX": 0, "deltaY": .number(distance),
          ]
        )
      ], channel, admit)
    await settle()
    let after = try await evaluate(channel, "scrollY", landed: true).number ?? before
    let moved = distance > 0 ? after > before : after < before
    return DispatchOutcome(verified: moved, verdict: moved ? "scrolled" : "scroll-unchanged")
  }

  /// The only addresses an agent may open.
  public static func isWebAddress(_ url: String) -> Bool {
    guard let parsed = URL(string: url) else { return false }
    return ["http", "https"].contains(parsed.scheme?.lowercased()) && parsed.host != nil
  }

  /// Verified by the main frame having a new document (its loader id changed).
  @MainActor
  public static func navigate(
    url: String, channel: CDPChannel, admit: Admit, settle: Settle = {}
  ) async throws -> DispatchOutcome {
    guard isWebAddress(url) else {
      throw Failure(message: "only http and https addresses can be opened", effectPossible: false)
    }
    let before = try await precheck(channel, admit)
    let reply = try await write([("Page.navigate", ["url": .string(url)])], channel, admit)[0]
    if let refused = reply["errorText"]?.string {
      throw Failure(message: refused, effectPossible: false)
    }
    await settle()
    let after = try await readKeys(channel, landed: true)
    let changed = after.documentKey != before.documentKey
    return DispatchOutcome(
      verified: changed, verdict: changed ? "document-changed" : "document-unchanged")
  }

  /// The element's state, or the focused element's when there is no `ref` (a key goes where the
  /// focus is). An element that no longer resolves after the write reads as nil: it is gone.
  private static func snapshot(ref: Int?, _ channel: CDPChannel, landed: Bool) async throws
    -> PageSnapshot?
  {
    let reply: JSON
    do {
      if let ref {
        reply = try await Extractor.callOnNode(channel, ref: ref, function: PageSnapshot.script)
      } else {
        reply = try await Extractor.evaluateInIsolatedWorld(
          transport: channel,
          expression: "(\(PageSnapshot.script)).call(document.activeElement || document.body)")
      }
    } catch let error as CDPError {
      if ref != nil, case .remote(_, let message) = error, Self.nodeGone(message) { return nil }
      throw Failure(message: "read-back failed: \(error)", effectPossible: landed)
    }
    guard let snapshot = PageSnapshot(json: reply) else {
      throw Failure(message: "unexpected read-back reply", effectPossible: landed)
    }
    return snapshot
  }

  /// Only a node the page has positively dropped reads as gone; any other failed read is unknown.
  private static func nodeGone(_ message: String) -> Bool {
    let text = message.lowercased()
    return text.contains("no node") || text.contains("could not find node")
      || text.contains("does not resolve")
  }

  private static func snapshotBefore(ref: Int?, _ channel: CDPChannel) async throws
    -> PageSnapshot
  {
    guard let before = try await snapshot(ref: ref, channel, landed: false) else {
      throw Failure(message: "cannot read the element", effectPossible: false)
    }
    return before
  }

  private static func readBackEffect(
    ref: Int?, before: PageSnapshot, keysBefore: PageKeys, _ channel: CDPChannel
  ) async throws -> DispatchOutcome {
    let keysAfter = try await readKeys(channel, landed: true)
    let changed = keysAfter.documentKey != keysBefore.documentKey
    // nil: the page removed the node, so it no longer resolves.
    let after = changed ? nil : try await snapshot(ref: ref, channel, landed: true)
    return ReadBack.click(before: before, after: after, documentChanged: changed)
  }

  private static func readCaret(_ ref: Int, _ channel: CDPChannel) async throws -> ReadBack.Caret {
    let reply: JSON
    do {
      reply = try await Extractor.callOnNode(channel, ref: ref, function: ReadBack.Caret.script)
    } catch let error as CDPError {
      throw Failure(message: "cannot read the caret: \(error)", effectPossible: false)
    }
    guard let caret = ReadBack.Caret(json: reply) else {
      throw Failure(message: "unexpected caret reply", effectPossible: false)
    }
    return caret
  }

  private static func evaluate(_ channel: CDPChannel, _ expression: String, landed: Bool = false)
    async throws -> JSON
  {
    do {
      return try await Extractor.evaluateInIsolatedWorld(transport: channel, expression: expression)
    } catch let error as CDPError {
      throw Failure(message: "cannot read the page: \(error)", effectPossible: landed)
    }
  }

  private struct Spot {
    let x: Double
    let y: Double
    let onscreen: Bool
    let hit: Bool
    let editable: Bool
  }

  private static func locate(_ ref: Int, _ transport: any CDPTransport) async throws -> Spot {
    let reply: JSON
    do {
      reply = try await Extractor.callOnNode(transport, ref: ref, function: locateScript)
    } catch let error as CDPError {
      throw Failure(message: "cannot locate the element: \(error)", effectPossible: false)
    }
    guard let x = reply["x"]?.number, let y = reply["y"]?.number,
      let onscreen = reply["onscreen"]?.bool,
      let hit = reply["hit"]?.bool, let editable = reply["editable"]?.bool
    else { throw Failure(message: "unexpected locate reply", effectPossible: false) }
    return Spot(x: x, y: y, onscreen: onscreen, hit: hit, editable: editable)
  }

  /// Run first so a stale action is named as stale rather than failing to find its element in a
  /// page that has moved on. The write checks again.
  @MainActor
  @discardableResult
  private static func precheck(_ channel: CDPChannel, _ admit: Admit) async throws -> PageKeys {
    let keys = try await readKeys(channel, landed: false)
    if let reason = admit(keys) { throw Stale(reason: reason) }
    return keys
  }

  private static func readKeys(_ channel: CDPChannel, landed: Bool) async throws -> PageKeys {
    do {
      return try await PageKeys.read(channel)
    } catch {
      throw Failure(message: "page keys: \(error)", effectPossible: landed)
    }
  }

  /// A page whose window is not key holds back the events of `DOM.focus` until its first input
  /// arrives, so a handler that retypes the field would run after the last check. Emulated focus
  /// runs them inside the call, ahead of `confirm`.
  @MainActor
  private static func withFocusEmulation<T>(
    _ channel: CDPChannel, _ body: () async throws -> T
  ) async rethrows -> T {
    _ = channel.submit("Emulation.setFocusEmulationEnabled", ["enabled": true])
    defer { _ = channel.submit("Emulation.setFocusEmulationEnabled", ["enabled": false]) }
    return try await body()
  }

  private static func confirm(_ recheck: Recheck?) async throws {
    if let recheck, !(await recheck()) { throw Stale(reason: .target) }
  }

  /// A page can answer a focus with a script that moves focus elsewhere; text typed then would
  /// land in the wrong field.
  private static func requireFocus(_ ref: Int, _ channel: CDPChannel) async throws {
    let focused: JSON
    do {
      focused = try await Extractor.callOnNode(channel, ref: ref, function: focusScript)
    } catch let error as CDPError {
      throw Failure(message: "cannot confirm focus: \(error)", effectPossible: false)
    }
    guard focused.bool == true else {
      throw Failure(message: focusRedirected, effectPossible: false)
    }
  }

  /// `landed` is true when an earlier write of the same action already reached the page.
  /// `beforeAdmit` is the last thing awaited: its verdict is acted on in the same main-actor run as
  /// the admission and the sends. Its failure is raised only after admission, so a takeover that
  /// moved the focus is reported as stale rather than as the page's doing.
  @MainActor
  @discardableResult
  private static func write(
    _ calls: [(method: String, params: JSON)], _ channel: CDPChannel, _ admit: Admit,
    landed: Bool = false, beforeAdmit: (() async throws -> Void)? = nil
  ) async throws -> [JSON] {
    let keys = try await readKeys(channel, landed: landed)
    var unmet: (any Error)?
    do { try await beforeAdmit?() } catch { unmet = error }
    // The check and the sends are one run of main-actor code: nothing can interleave between them.
    if let reason = admit(keys) {
      throw Stale(reason: reason)
    }
    if let unmet { throw unmet }
    let replies = calls.map { channel.submit($0.method, $0.params) }
    var results: [JSON] = []
    for (call, reply) in zip(calls, replies) {
      do {
        results.append(try await reply())
      } catch let error as CDPError {
        // Every call of a batch is already on its way, so a refusal of any one of them cannot
        // rule out the others (a press whose release failed).
        throw Failure(
          message: "\(call.method): \(error)",
          effectPossible: landed || calls.count > 1 || error.mayHaveReachedThePage)
      }
    }
    return results
  }

  private static let locateScript = #"""
    function () {
      const box = this.getBoundingClientRect();
      const x = box.left + box.width / 2, y = box.top + box.height / 2;
      const onscreen = box.width > 0 && box.height > 0 && x >= 0 && y >= 0
        && x < innerWidth && y < innerHeight;
      const top = onscreen ? this.getRootNode().elementFromPoint(x, y) : null;
      const textual = this.tagName === "TEXTAREA" || (this.tagName === "INPUT" && ![
        "checkbox", "radio", "button", "submit", "reset", "file", "image", "range", "color",
        "hidden"].includes(this.type));
      return {
        x, y, onscreen, hit: !!top && (top === this || this.contains(top)),
        editable: this.isContentEditable || (textual && !this.readOnly && !this.disabled),
      };
    }
    """#

  /// `getRootNode()` makes this hold for nodes inside shadow roots, where the document's own
  /// `activeElement` is only the host.
  private static let focusScript =
    "function () { return this.getRootNode().activeElement === this; }"

  private static let selectScript = #"""
    function (wanted) {
      if (this.tagName !== "SELECT" || this.disabled) return { ok: false, reason: "not-a-select" };
      const options = Array.from(this.options);
      const option = options.find((o) => o.value === wanted)
        || options.find((o) => o.label === wanted || o.text.trim() === wanted);
      if (!option || option.disabled) return { ok: false, reason: "no-such-option" };
      this.value = option.value;
      const chosen = this.value;
      this.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      this.dispatchEvent(new Event("change", { bubbles: true }));
      return { ok: true, value: chosen };
    }
    """#

  private static let readBack =
    "function () { return this.isContentEditable ? this.textContent : this.value; }"
}

extension CDPError {
  /// A refusal or a message that was never written cannot have landed; a timeout might have.
  fileprivate var mayHaveReachedThePage: Bool {
    switch self {
    case .timeout, .closed: true
    case .sendFailed, .remote: false
    }
  }
}
