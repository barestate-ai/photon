import BarestateCore
import Foundation

/// What an act aims at: an element the caller named from an observation, words for the ladder to
/// ground, or nothing (the page itself).
enum ActTarget {
  case ref(Int)
  case instruction(String)
  case page
}

/// The parameters of `act`, parsed once at the socket boundary.
struct ActRequest {
  let sessionId: String
  let clientActionId: String
  let observationId: String
  let kind: ActionKind
  let target: ActTarget
  /// The text to type, or the option to select.
  let text: String?
  let key: PressKey?
  let direction: ScrollDirection?
  let amount: Double?
  let url: String?

  init(_ params: JSON) throws {
    sessionId = try params.requireString("sessionId")
    clientActionId = try params.requireString("clientActionId")
    observationId = try params.requireString("observationId")
    guard let kind = params["kind"]?.string.flatMap(ActionKind.init(rawValue:)) else {
      throw RPCError.invalidParams("kind must be click, type, select, press, scroll or navigate")
    }
    self.kind = kind
    let ref = params["ref"]?.int
    let words = params["instruction"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    var text: String?
    var key: PressKey?
    var direction: ScrollDirection?
    var url: String?
    switch kind {
    case .click, .type, .select:
      if let ref {
        target = .ref(ref)
      } else if let words, !words.isEmpty {
        target = .instruction(words)
      } else {
        throw RPCError.invalidParams("ref (integer) or instruction (string) required")
      }
      if kind != .click {
        let field = kind == .type ? "text" : "value"
        text = params[field]?.string
        if (text ?? "").isEmpty {
          throw RPCError.invalidParams("\(field) (non-empty string) required for \(kind.rawValue)")
        }
      }
    case .press:
      let name = try params.requireString("key")
      guard let parsed = PressKey.parse(name) else {
        throw RPCError.invalidParams("key: a named key or one letter or digit, no chords")
      }
      key = parsed
      target = ref.map(ActTarget.ref) ?? .page
    case .scroll:
      guard let parsed = ScrollDirection(rawValue: try params.requireString("direction")) else {
        throw RPCError.invalidParams("direction must be up or down")
      }
      direction = parsed
      target = .page
    case .navigate:
      url = try params.requireString("url")
      target = .page
    }
    self.text = text
    self.key = key
    self.direction = direction
    amount = params["amount"]?.number
    self.url = url
  }

  /// What the journal row says the act is aimed at, before anything is resolved.
  private var targetText: String {
    switch kind {
    case .press: key?.name ?? ""
    case .scroll: direction?.rawValue ?? ""
    case .navigate: url ?? ""
    default:
      switch target {
      case .ref(let ref): String(ref)
      case .instruction(let words): words
      case .page: ""
      }
    }
  }

  func journalEntry(tab: Tab?, observation: Observation?) -> NewAction {
    var rung: String?
    if case .ref = target { rung = Rung.ref.rawValue }
    return NewAction(
      sessionId: sessionId, clientActionId: clientActionId, tabId: tab?.id,
      epoch: observation?.epoch, observationId: observationId, kind: kind.rawValue,
      target: targetText, textHash: text.map(NewAction.hash), rung: rung)
  }
}

/// The act pipeline (architecture §5.4): journal row → resolve ref → permission → hold →
/// admit + dispatch → read-back → final state. The row is `pending` before anything reaches the
/// page, and a repeated (session, clientActionId) returns it instead of acting again.
@MainActor
final class Actions {
  private let controller: AppController
  private var approvals: Approvals { controller.approvals }
  private let store: @MainActor () -> Store?
  let grounders: Grounders
  /// What `test.verifier` can put in place of the model's reading of the two screenshots.
  enum VerifierStub: String {
    /// Says what the page read-back said, so a test of the write alone sees `confirmed`/`failed`.
    case agree, success, failure, unavailable
  }

  var verifierStub: VerifierStub?
  /// The words the stand-in gives for its verdict, so a test can follow them to the logs.
  var verifierWhy = "stub"
  private(set) var verifierCalls = 0
  private var held = false
  /// Muse's safety checks for a quoted act, sent only if a person allows it.
  private var safetyAcks: [Int: SafetyAck] = [:]
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var tails: [ObjectIdentifier: Task<Void, Never>] = [:]

  init(controller: AppController, store: @escaping @MainActor () -> Store?) {
    self.controller = controller
    self.store = store
    grounders = Grounders(controller: controller)
  }

  /// Test hook support: while on, actions stop after their row is written and before dispatch.
  func hold(_ on: Bool) {
    held = on
    if on { return }
    let released = waiting
    waiting = []
    for continuation in released { continuation.resume() }
  }

  func act(_ params: JSON) async throws -> JSON {
    let request = try ActRequest(params)
    guard let store = store() else { throw RPCError.failure("the journal is not open") }
    let (tab, observation) = locate(request.observationId)
    do {
      let (row, created) = try await store.record(
        request.journalEntry(tab: tab, observation: observation))
      guard created else { return row.json }
      guard let tab, let observation else {
        return try await store.end(row, .failed, "unknown-observation").json
      }
      do {
        if case .ref(let ref) = request.target {
          _ = try observation.target(ref: ref, for: request.kind)
        }
      } catch let rejection as ActionRejection {
        return try await store.end(row, .failed, rejection.rawValue).json
      }
      guard tab.control.controller == .agent(request.sessionId) else {
        return try await store.end(row, .failed, "not-in-control").json
      }
      if held {
        Task { [self] in
          await waitForRelease()
          do {
            _ = try await finish(row, request, tab, observation, store)
          } catch {
            Log.error(.runs, "held act \(row.id) failed: \(Log.describe(error))")
          }
        }
        return row.json
      }
      return try await finish(row, request, tab, observation, store)
    } catch let error as Store.Failure {
      throw RPCError.failure("journal: \(error.message)")
    }
  }

  func status(_ params: JSON) async throws -> JSON {
    guard let store = store() else { throw RPCError.failure("the journal is not open") }
    let row: ActionRow?
    if let id = params["actionId"]?.int {
      row = await store.action(id: id)
    } else {
      row = await store.action(
        sessionId: try params.requireString("sessionId"),
        clientActionId: try params.requireString("clientActionId"))
    }
    guard let row else { throw RPCError.failure("no such action") }
    return row.json
  }

  private func waitForRelease() async {
    guard held else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  private func locate(_ observationId: String) -> (Tab?, Observation?) {
    for tab in controller.tabs {
      if let observation = tab.observation(id: observationId) { return (tab, observation) }
    }
    return (nil, nil)
  }

  /// One action per tab at a time: a focus followed by a text insert must not be split by another
  /// action's focus. Admission is checked again after the wait.
  private func serial(
    _ tab: Tab, _ body: @escaping @MainActor () async throws -> ActionRow
  ) async throws -> JSON {
    let key = ObjectIdentifier(tab)
    let previous = tails[key]
    let turn = Task { [self] in
      _ = await previous?.value
      // A row that ends before dispatch must not report the previous act's settle.
      tab.settling.disarm()
      var fields = try await body().json.object ?? [:]
      fields["settle"] = tab.settling.last?.json
      return JSON.object(fields)
    }
    tails[key] = Task { _ = await turn.result }
    return try await turn.value
  }

  private func finish(
    _ row: ActionRow, _ request: ActRequest, _ tab: Tab, _ observation: Observation, _ store: Store
  ) async throws -> JSON {
    try await serial(tab) { [self] in try await deliver(row, request, tab, observation, store) }
  }

  private func deliver(
    _ row: ActionRow, _ request: ActRequest, _ tab: Tab, _ observation: Observation, _ store: Store
  ) async throws -> ActionRow {
    var ref: Int?
    var holdReason: String?
    var ack: SafetyAck?
    switch request.target {
    case .ref(let named): ref = named
    case .page: break
    case .instruction(let words):
      switch await grounders.resolve(
        instruction: words, tab: tab, elements: observation.elements, session: request.sessionId)
      {
      case .failed(let reason): return try await store.end(row, .failed, reason)
      case .resolved(let found, let rung):
        try await store.resolve(id: row.id, target: String(found), rung: rung.rawValue)
        if rung == .dom, !(await stillNamed(words, ref: found, tab)) {
          return try await store.end(row, .cancelled, "stale: \(StaleReason.target.rawValue)")
        }
        // FT4: Atom's measured hit rate decides whether its clicks may run without a human.
        if rung == .atom && grounders.policy.atomNeedsApproval {
          holdReason = "atom-grounded: needs approval (FT4)"
        }
        ref = found
        if rung == .muse { ack = grounders.takeAck(tab) }
      }
    }
    let element = ref.flatMap { ref in observation.elements.first { $0.ref == ref } }
    // Read the control again: what the page calls it now decides, and a control that cannot be
    // read is treated as sensitive.
    var live: LiveTarget?
    var sensitive = false
    if Self.writesToTarget(request.kind), ref != nil || request.kind == .press {
      live = await LiveTarget.read(ref: ref, transport: tab.channel)
      // A page that moved on is stale, not sensitive: its refs no longer read.
      if live == nil, let keys = try? await PageKeys.read(tab.channel),
        case .stale(let reason) = tab.control.admit(
          session: request.sessionId, observation: observation, current: keys)
      {
        return try await store.end(row, .cancelled, "stale: \(reason.rawValue)")
      }
      sensitive = element?.sensitive == true || live?.isSensitive(pressing: request.key) ?? true
    }
    if sensitive || holdReason != nil {
      safetyAcks[row.id] = ack
      return try await quote(
        row, request, ref: ref, element: element, live: live, sensitive: sensitive,
        reason: holdReason ?? "sensitive: needs approval", tab, observation, store)
    }
    if let ack, await stillAdmitted(request, tab, observation) {
      await grounders.acknowledge(ack, tab: tab, session: request.sessionId)
    }
    return try await dispatchRow(
      row, request, ref: ref, element: element, sensitive: false, live: live, tab, observation,
      store)
  }

  private static func writesToTarget(_ kind: ActionKind) -> Bool {
    [.click, .type, .select, .press].contains(kind)
  }

  /// Holds the row `quoted` and returns it; the action goes on only if a human allows it, once.
  private func quote(
    _ row: ActionRow, _ request: ActRequest, ref: Int?, element: Element?, live: LiveTarget?,
    sensitive: Bool, reason: String, _ tab: Tab, _ observation: Observation, _ store: Store
  ) async throws -> ActionRow {
    let binding = ApprovalBinding(
      tabId: tab.id, epoch: observation.epoch, documentKey: observation.documentKey,
      ref: ref ?? Self.focusedRef,
      kind: request.kind, textHash: row.textHash)
    let held = try await store.quote(
      id: row.id, tokenHash: binding.token, sensitive: sensitive, reason: reason)
    guard held.state == .quoted else { return held }
    // A by-ref press focuses its host before the final recheck, which would hide that the focus
    // left it while the approval waited: a host that had it now must still have it at release. An
    // unreadable focus counts as held, so release cancels rather than guess.
    var focusHeld = false
    if request.kind == .press, let ref, live?.opaque == true {
      let focused = await LiveTarget.read(ref: nil, transport: tab.channel)?.node
      focusHeld = focused == nil || focused == ref
    }
    let approval = approvals.hold(
      rowId: row.id, tabId: tab.id, sessionId: request.sessionId,
      text: Self.describe(
        request, name: live?.label ?? element?.name, submits: live?.submitting(on: request.key),
        reveal: true),
      epoch: observation.epoch, tracksFocus: ref == nil && request.kind == .press)
    // A takeover or a closed tab may have come while the row waited for its turn.
    controller.reapApprovals()
    Log.info(.runs, "act id=\(row.id) state=quoted approval=\(approval)")
    Task { [self] in
      defer { safetyAcks[row.id] = nil }
      switch await approvals.decision(of: approval) {
      case .allow:
        do {
          _ = try await serial(tab) { [self] in
            try await release(
              row, request, binding, ref: ref, element: element, live: live, sensitive: sensitive,
              focusHeld: focusHeld, tab, observation, store)
          }
        } catch {
          Log.error(.runs, "approved act \(row.id) failed: \(Log.describe(error))")
        }
      case .deny:
        _ = try? await store.end(row, .cancelled, "denied")
      case .stale(let why):
        _ = try? await store.end(row, .cancelled, "stale: \(why)")
      }
    }
    return held
  }

  /// The token is recomputed from the page as it is now; anything that moved cancels the action.
  private func release(
    _ row: ActionRow, _ request: ActRequest, _ binding: ApprovalBinding, ref: Int?,
    element: Element?, live: LiveTarget?, sensitive: Bool, focusHeld: Bool,
    _ tab: Tab, _ observation: Observation, _ store: Store
  ) async throws -> ActionRow {
    guard let keys = try? await PageKeys.read(tab.channel) else {
      return try await store.end(row, .cancelled, "stale: page unreadable")
    }
    let now = ApprovalBinding(
      tabId: tab.id, epoch: tab.control.epoch, documentKey: keys.documentKey,
      ref: ref ?? Self.focusedRef, kind: request.kind, textHash: binding.textHash)
    if let stale = binding.staleReason(against: now) {
      return try await store.end(row, .cancelled, "stale: \(stale.rawValue)")
    }
    // The control the person allowed must still be the one that is there (or, for a key with no
    // ref, the one that has the focus). A write that was quoted because its control could not be
    // read has nothing to be held to, so it is not delivered.
    if Self.writesToTarget(request.kind) {
      if focusHeld, await LiveTarget.read(ref: nil, transport: tab.channel)?.node != ref {
        return try await store.end(row, .cancelled, "stale: \(StaleReason.target.rawValue)")
      }
      guard let live, await LiveTarget.read(ref: ref, transport: tab.channel) == live else {
        return try await store.end(row, .cancelled, "stale: \(StaleReason.target.rawValue)")
      }
    }
    guard try await store.approve(id: row.id) else {
      return await store.action(id: row.id) ?? row
    }
    if let ack = safetyAcks.removeValue(forKey: row.id),
      await stillAdmitted(request, tab, observation)
    {
      await grounders.acknowledge(ack, tab: tab, session: request.sessionId)
    }
    return try await dispatchRow(
      row, request, ref: ref, element: element, sensitive: sensitive, live: live, approved: true,
      tab, observation, store)
  }

  /// The model is told its click was allowed only if dispatch would admit it now.
  private func stillAdmitted(_ request: ActRequest, _ tab: Tab, _ observation: Observation) async
    -> Bool
  {
    guard let keys = try? await PageKeys.read(tab.channel) else { return false }
    if case .ok = tab.control.admit(
      session: request.sessionId, observation: observation, current: keys)
    {
      return true
    }
    return false
  }

  /// The ref a key press with no target is bound to: whatever has the focus.
  private static let focusedRef = -1

  private func dispatchRow(
    _ row: ActionRow, _ request: ActRequest, ref: Int?, element: Element?, sensitive: Bool,
    live: LiveTarget?, approved: Bool = false, _ tab: Tab, _ observation: Observation,
    _ store: Store
  ) async throws -> ActionRow {
    let admit: Dispatch.Admit = { keys in
      let admission = tab.control.admit(
        session: request.sessionId, observation: observation, current: keys)
      if case .stale(let reason) = admission { return reason }
      return nil
    }
    let before = try? await Verifier.capture(tab.channel)
    let watch = await Settling.prepare(tab.channel)
    tab.settling.arm(mainFrame: PageKeys.mainFrameId(documentKey: observation.documentKey))
    defer { Settling.release(tab.channel, context: watch) }
    // The server may have acted on a navigation Barestate stopped: whatever the read-back says,
    // the row says so and is never confirmed or retried.
    func end(
      _ state: ActionState, _ reason: String?, _ verdict: String? = nil, model: String? = nil
    ) async throws -> ActionRow {
      if tab.settling.last?.navigationStopped == true {
        return try await store.end(row, .outcomeUnknown, Self.navigationStopped, verdict, model)
      }
      return try await store.end(row, state, reason, verdict, model)
    }
    do {
      let result = try await dispatch(
        request, ref: ref, tab, admit, recheck: recheck(live, ref, approved, request, tab))
      if tab.settling.last?.navigationStopped == true {
        return try await end(.outcomeUnknown, nil, result.verdict)
      }
      let after = try? await Verifier.capture(tab.channel)
      let model = await modelVerdict(
        intent: Self.describe(
          request, name: live?.label ?? element?.name, reveal: !sensitive),
        before: before, after: after, rowId: row.id, session: request.sessionId, dom: result)
      let verdict = Verifier.decide(dom: result, model: model)
      return try await end(verdict.state, verdict.reason, result.verdict, model: model.stored)
    } catch let stale as Dispatch.Stale {
      // A control that turned sensitive after the check (focus can do that) is quoted, not written.
      if stale.reason == .target, !approved,
        let now = await LiveTarget.read(ref: ref, transport: tab.channel),
        now.isSensitive(pressing: request.key)
      {
        return try await quote(
          row, request, ref: ref, element: element, live: now, sensitive: true,
          reason: "sensitive: needs approval", tab, observation, store)
      }
      return try await end(.cancelled, "stale: \(stale.reason.rawValue)")
    } catch let failure as Dispatch.Failure {
      return try await end(failure.effectPossible ? .outcomeUnknown : .failed, failure.message)
    } catch {
      return try await end(.outcomeUnknown, "\(error)")
    }
  }

  /// A key and typed text go to whatever has the focus, so those are read there; a click or a
  /// select is aimed at its ref.
  private static func read(_ ref: Int?, _ request: ActRequest, _ tab: Tab) async -> LiveTarget? {
    let focusBound = request.kind == .type || request.kind == .press
    return await LiveTarget.read(ref: focusBound ? nil : ref, transport: tab.channel)
  }

  /// Asked just before the write. After Allow once the control must be the very one that was
  /// quoted, node included (a twin with the same name is another control); before it, the control
  /// must not have become sensitive since it was read. Where the input will land must be the
  /// target: typing or a key aimed at a ref fails if the focus is anywhere else.
  private func recheck(
    _ live: LiveTarget?, _ ref: Int?, _ approved: Bool, _ request: ActRequest, _ tab: Tab
  ) -> Dispatch.Recheck? {
    guard let live else { return nil }
    return {
      guard let now = await Self.read(ref, request, tab), ref == nil || now.node == ref
      else { return false }
      return approved ? now == live : !now.isSensitive(pressing: request.key)
    }
  }

  /// The model's reading of the two pictures; the stub stands in for it under test hooks.
  private func modelVerdict(
    intent: String, before: Data?, after: Data?, rowId: Int, session: String, dom: DispatchOutcome
  ) async -> ModelVerdict {
    verifierCalls += 1
    switch verifierStub {
    case .agree: return dom.verified ? .success(verifierWhy) : .failure(verifierWhy)
    case .success: return .success(verifierWhy)
    case .failure: return .failure(verifierWhy)
    case .unavailable: return .unavailable(verifierWhy)
    case nil: break
    }
    guard let before, let after else { return .unavailable("no screenshot") }
    keep(before, after, rowId: rowId)
    return await Verifier.verify(
      intent: intent, before: before, after: after,
      client: controller.modelClient(session: session))
  }

  /// The pictures the model saw, for whoever has to explain a verdict.
  private func keep(_ before: Data, _ after: Data, rowId: Int) {
    let base = "\(controller.dataDir.tmp)/verify-\(rowId)"
    try? FileManager.default.createDirectory(
      atPath: controller.dataDir.tmp, withIntermediateDirectories: true)
    try? before.write(to: URL(fileURLWithPath: base + "-before.jpg"))
    try? after.write(to: URL(fileURLWithPath: base + "-after.jpg"))
  }

  /// The action in words, with the target's name in quotes. `reveal` leaves out typed text.
  static func describe(
    _ request: ActRequest, name label: String?, submits: String? = nil, reveal: Bool
  ) -> String {
    let name = label.map { "\"\($0)\"" }
    switch request.kind {
    case .click: return "Click " + (name ?? "the page")
    case .type:
      let text = reveal ? "\"\(request.text ?? "")\"" : "text"
      return "Type \(text) into " + (name ?? "the field")
    case .select: return "Select \"\(request.text ?? "")\" in " + (name ?? "the list")
    case .press:
      return "Press \"\(request.key?.name ?? "")\"" + (name.map { " on " + $0 } ?? "")
        + (submits.map { ", which submits \"\($0)\"" } ?? "")
    case .scroll: return "Scroll \(request.direction?.rawValue ?? "down")"
    case .navigate: return "Open \(request.url ?? "")"
    }
  }

  private static let navigationStopped = "navigation stopped: no response in 10 s"

  /// The DOM rung matched the observation's names, and admission only compares the page's keys, so
  /// a rename in the same document (Save to Cancel) would go unnoticed. A node that is gone or
  /// unreadable counts as renamed.
  private func stillNamed(_ words: String, ref: Int, _ tab: Tab) async -> Bool {
    guard let now = try? await PointProbe.words(ref: ref, transport: tab.channel) else {
      return false
    }
    return InstructionMatch.matches(words, fields: now)
  }

  private func dispatch(
    _ request: ActRequest, ref: Int?, _ tab: Tab, _ admit: @escaping Dispatch.Admit,
    recheck: Dispatch.Recheck?
  ) async throws -> DispatchOutcome {
    let epoch = tab.control.epoch
    let settle: Dispatch.Settle = {
      let settled = await tab.settling.wait()
      // Only while the agent still holds the tab: after a takeover the navigation may be the
      // person's. Not awaited: it goes out ahead of `release`'s disables and is answered at once.
      if settled.navigationHanging, tab.settling.isHangingNow(), tab.control.epoch == epoch,
        tab.control.controller == .agent(request.sessionId)
      {
        _ = tab.channel.submit("Page.stopLoading", [:])
        tab.settling.markStopped()
      }
      Log.info(
        .runs,
        "settled ms=\(Int(settled.elapsedMs)) capped=\(settled.capped) hanging=\(settled.navigationHanging)"
      )
    }
    let channel = tab.channel
    func named() throws -> Int {
      guard let ref else { throw Dispatch.Failure(message: "no target", effectPossible: false) }
      return ref
    }
    switch request.kind {
    case .click:
      return try await Dispatch.click(
        ref: try named(), channel: channel, admit: admit, settle: settle, recheck: recheck)
    case .type:
      return try await Dispatch.type(
        ref: try named(), text: request.text ?? "", channel: channel, admit: admit, settle: settle,
        recheck: recheck)
    case .select:
      return try await Dispatch.select(
        ref: try named(), value: request.text ?? "", channel: channel, admit: admit, settle: settle,
        recheck: recheck)
    case .press:
      guard let key = request.key else {
        throw Dispatch.Failure(message: "no key", effectPossible: false)
      }
      return try await Dispatch.press(
        key, ref: ref, channel: channel, admit: admit, settle: settle, recheck: recheck)
    case .scroll:
      return try await Dispatch.scroll(
        direction: request.direction ?? .down, amount: request.amount, channel: channel,
        admit: admit, settle: settle)
    case .navigate:
      return try await Dispatch.navigate(
        url: request.url ?? "", channel: channel, admit: admit, settle: settle)
    }
  }
}

extension Store {
  fileprivate func end(
    _ row: ActionRow, _ state: ActionState, _ reason: String?, _ verdict: String? = nil,
    _ model: String? = nil
  ) throws -> ActionRow {
    Log.info(.runs, "act id=\(row.id) state=\(state.rawValue)")
    return try settle(
      id: row.id, state: state, reason: reason, domVerdict: verdict, modelVerdict: model)
  }
}

@MainActor
func registerActMethods(_ dispatcher: RPCDispatcher, actions: Actions) {
  dispatcher.register("act") { try await actions.act($0) }
  dispatcher.register("action_status") { try await actions.status($0) }
}
