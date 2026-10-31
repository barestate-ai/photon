import BarestateCore
import Foundation

/// Owns the runs this process has started and drives each one (architecture §5.10): the agent
/// loop on `muse-spark-1.3`, with the same socket methods an MCP client would call as its tools.
@MainActor
final class RunController {
  private var book = RunBook()
  private var tasks: [String: Task<Void, Never>] = [:]
  /// The phone session each phone run was started for.
  private var remoteSessions: [String: String] = [:]
  /// The tabs a phone run opened; it never touches any other (D9).
  private var ownedTabs: [String: Set<String>] = [:]
  /// Journal rows of each run's acts, to judge the run by when it ends.
  private var acts: [String: [Int]] = [:]
  private var actCount = 0
  /// Cost a test put on the next run, standing in for tokens spent before it started.
  private var seeds: [String: Double] = [:]
  var nextRunSeedUSD = 0.0
  /// Test hook: runs wait before their next model call, so a run stays where it is.
  var holdModel = false
  /// `test.breakChain`: the next chained loop request names a response the provider never issued.
  var breakChain = false
  private weak var app: AppController?
  private var dispatcher: RPCDispatcher?
  /// Separates this launch's run ids in the journal and the spend log from an earlier launch's.
  private let launch = String(Int(Date().timeIntervalSince1970), radix: 36)
  /// Called after a run starts or changes, for what shows its status.
  var onChange: (() -> Void)?

  func attach(app: AppController, dispatcher: RPCDispatcher) {
    self.app = app
    self.dispatcher = dispatcher
  }

  var runs: [Run] { book.runs }

  func run(_ id: String) -> Run? { book.runs.first { $0.id == id } }

  /// The tasks that belong to a page, oldest first.
  func runs(ownedBy tab: String?) -> [Run] { book.runs(ownedBy: tab) }

  func session(_ id: String) -> String { "\(id).\(launch)" }

  func start(prompt: String, origin: RunOrigin, tabId: String?, remoteSession: String? = nil)
    -> Run?
  {
    guard let run = book.start(prompt: prompt, origin: origin, ownerTabId: tabId) else {
      return nil
    }
    remoteSessions[run.id] = remoteSession
    seeds[run.id] = nextRunSeedUSD
    nextRunSeedUSD = 0
    // The run controls its page from the start; a person's next input takes it back.
    if let tabId, let tab = app?.tab(id: tabId) { tab.control.grant(session: session(run.id)) }
    Log.info(
      .runs,
      "start run=\(run.id) origin=\(run.origin.rawValue) state=\(run.state.rawValue) "
        + "tab=\(run.ownerTabId ?? "-")")
    onChange?()
    tasks[run.id] = Task { [weak self] in await self?.drive(run.id) }
    return run
  }

  /// Ends a run that has not ended; the loop sees it before its next model call or tool.
  @discardableResult
  func end(_ id: String, _ state: RunState, reason: String?) -> Bool {
    _ = withinCap(id)  // the last response's cost belongs in the ended run's total
    guard book.move(id, to: state, reason: reason) else { return false }
    tasks[id]?.cancel()
    tasks[id] = nil
    let session = session(id)
    // Whatever the run left for a person to decide goes with it: the card leaves, quoted rows
    // are cancelled.
    if let approvals = app?.approvals {
      for item in approvals.items where item.sessionId == session {
        approvals.resolve(item.id, .stale("run-ended"))
      }
    }
    for tab in app?.tabs ?? [] where tab.control.controller == .agent(session) {
      tab.control.handoff()
    }
    Log.info(
      .runs, "end run=\(id) state=\(state.rawValue) reason=\(RunOutcome.logCategory(reason))")
    onChange?()
    return true
  }

  /// Moves a run that has not ended between running and waiting for approval.
  @discardableResult
  private func advance(_ id: String, to state: RunState) -> Bool {
    guard book.move(id, to: state) else { return false }
    Log.info(.runs, "state run=\(id) state=\(state.rawValue)")
    onChange?()
    return true
  }

  /// Human input on a page this run controlled: the run is over before the input is delivered.
  func takenOver(from controller: TabControl.Controller) {
    guard case .agent(let session) = controller,
      let run = book.runs.first(where: { self.session($0.id) == session && $0.state.isInProgress })
    else { return }
    end(run.id, .stopped, reason: "taken-over")
  }

  func isOwned(_ id: String, by remoteSession: String) -> Bool {
    remoteSessions[id] == remoteSession
  }

  /// Stops what a phone session still has running, as its owner leaves.
  func endRuns(ofRemoteSession name: String, reason: String) {
    for run in book.runs where run.state.isInProgress && remoteSessions[run.id] == name {
      end(run.id, .stopped, reason: reason)
    }
  }

  /// A phone's takeover: the person takes the page back with the same effect as touching it.
  func takeOver(_ id: String) throws -> Run {
    guard let run = run(id) else { throw RPCError.failure("no such run \(id)") }
    guard run.state.isInProgress else { return run }
    if let tab = run.ownerTabId.flatMap({ app?.tab(id: $0) }) {
      let held = tab.control.controller
      tab.control.humanInput()
      takenOver(from: held)
    }
    end(id, .stopped, reason: "taken-over")
    return self.run(id)!
  }

  func stop(_ id: String) throws -> Run {
    guard run(id) != nil else { throw RPCError.failure("no such run \(id)") }
    end(id, .stopped, reason: "stopped")
    return run(id)!
  }

  /// Test hooks (`test.runState`, `test.runStep`): the state or step the loop would have reached,
  /// for the states the model cannot be made to reach on demand.
  func force(_ id: String, to state: RunState, reason: String?) -> Bool {
    guard let current = run(id)?.state else { return false }
    if state == .waitingApproval, current == .pending { advance(id, to: .running) }
    if state.isInProgress { return advance(id, to: state) }
    return end(id, state, reason: reason)
  }

  func record(
    _ id: String, text: String, tab: String?, state: String?, reason: String?
  ) -> Bool {
    let step = beginStep(id, kind: "act", text: text, tab: tab)
    if let state { endStep(id, step, state: state, reason: reason) }
    return step != nil
  }

  // MARK: Driving

  private func drive(_ id: String) async {
    guard let app, let run = run(id) else { return }
    let session = session(id)
    let end = await AgentLoop.run(
      prompt: opening(run),
      live: { self.run(id)?.state.isInProgress == true },
      withinCap: { self.withinCap(id) },
      replayed: { Log.info(.runs, "chain replay reason=missing-reference turn=\($0)") },
      model: { request in
        await self.wait(id) { self.holdModel }
        var request = request
        if self.breakChain, request.previousResponseId != nil {
          self.breakChain = false
          request.previousResponseId =
            "resp_" + String((0..<24).map { _ in "0123456789abcdef".randomElement()! })
        }
        let response: ModelResponse
        do {
          response = try await app.modelClient(session: session, retrying: true)
            .call(request, source: "loop")
        } catch let error as ModelError where error.isTransient {
          // A provider hiccup is not the task's failure; one more try, and nothing was billed.
          try await Task.sleep(for: .seconds(1))
          response = try await app.modelClient(session: session).call(request, source: "loop")
        }
        self.advance(id, to: .running)
        return response
      },
      tool: { await self.execute($0, run: id) })
    await conclude(id, end)
  }

  private func opening(_ run: Run) -> String {
    var words = "Task: \(run.prompt)\n"
    if let tab = run.ownerTabId.flatMap({ app?.tab(id: $0) }) {
      words += "Your page is \(tab.id), \"\(tab.title)\" (\(tab.url)), and you control it."
    } else {
      words += "You have no page yet. Open one with open_tab."
    }
    return words
  }

  /// Why a model call of this session must not go out, if it must not: the run it belongs to has
  /// ended or is at its cap. Sessions that are not a run's are never refused.
  func refusal(_ session: String) -> ModelError? {
    guard let run = book.runs.first(where: { self.session($0.id) == session }) else { return nil }
    if !run.state.isInProgress { return .refused("run ended") }
    return withinCap(run.id) ? nil : .refused("run-cap")
  }

  /// The run's own cost; a test's seed counts as spend before the run began.
  private func withinCap(_ id: String) -> Bool {
    let spent = (try? app?.spendLedger.spent(session: session(id))) ?? run(id)?.costUSD ?? 0
    let cost = spent + (seeds[id] ?? 0)
    book.setCost(run: id, usd: cost)
    return !RunCap.exceeded(cost)
  }

  private func conclude(_ id: String, _ end: AgentLoop.End) async {
    switch end {
    case .stopped: break
    case .failed(let reason): self.end(id, .failed, reason: reason)
    case .ended:
      var writes: [(state: ActionState, reason: String?)] = []
      for row in acts[id] ?? [] {
        if let action = await app?.database()?.action(id: row) {
          writes.append((action.state, action.reason))
        }
      }
      let outcome = RunOutcome.conclude(modelEnded: true, writes: writes)
      self.end(id, outcome.state, reason: outcome.reason)
    }
  }

  // MARK: Tools

  func execute(_ call: FunctionCall, run id: String) async -> String {
    guard let params = JSON.parse(Data(call.arguments.utf8)), params.object != nil else {
      return Self.failure("arguments are not a JSON object")
    }
    do {
      switch call.name {
      case "tabs", "handoff", "open_tab": return try await simple(call.name, params, id)
      case "observe", "extract": return try await read(call.name, params, id)
      case "act": return try await act(params, id)
      case "action_status": return try await status(params, id)
      case "request_control": return try await requestControl(params, id)
      default: return Self.failure("no tool named \(call.name)")
      }
    } catch {
      return Self.failure((error as? RPCError)?.message ?? Log.describe(error))
    }
  }

  private static func failure(_ message: String) -> String {
    JSON.object(["error": .string(message)]).serialized()
  }

  private func call(_ method: String, _ fields: [String: JSON]) async throws -> JSON {
    guard let dispatcher else { throw RPCError.failure("the app is not ready") }
    return try await dispatcher.call(method, .object(fields))
  }

  private func withSession(_ params: JSON, _ id: String) -> [String: JSON] {
    var fields = params.object ?? [:]
    fields["sessionId"] = .string(session(id))
    return fields
  }

  /// `withSession` for a call that acts on a tab. A phone run's call falls back to its own tab,
  /// never the Mac's active one, and naming any tab it did not open is refused.
  private func scoped(_ params: JSON, _ id: String) throws -> [String: JSON] {
    var fields = withSession(params, id)
    guard run(id)?.origin == .phone else { return fields }
    guard let tab = fields["tabId"]?.string ?? run(id)?.ownerTabId else {
      throw RPCError.failure("this run has no page yet; open one with open_tab")
    }
    try own(tab, run: id)
    fields["tabId"] = .string(tab)
    return fields
  }

  private func own(_ tab: String, run id: String) throws {
    guard run(id)?.origin != .phone || ownedTabs[id]?.contains(tab) == true else {
      throw RPCError.failure("\(tab) is not a page of this run; a phone run works only in its own")
    }
  }

  private func simple(_ name: String, _ params: JSON, _ id: String) async throws -> String {
    // The app's own `open_tab` takes any address; a run only gets web pages.
    if name == "open_tab", !Dispatch.isWebAddress(params["url"]?.string ?? "") {
      throw RPCError.failure("only http and https addresses can be opened")
    }
    var fields = name == "handoff" ? try scoped(params, id) : withSession(params, id)
    // A phone run works in a tab of its own, never in the one the person is looking at.
    if name == "open_tab", run(id)?.origin == .phone { fields["activate"] = false }
    var result = try await call(name, fields)
    if name == "open_tab", let tabId = result["id"]?.string, let tab = app?.tab(id: tabId) {
      tab.control.grant(session: session(id))
      book.setOwner(id, tab: tabId)
      ownedTabs[id, default: []].insert(tabId)
      for _ in 0..<150 where tab.loading { try? await Task.sleep(for: .milliseconds(100)) }
      result = app?.describe(tab) ?? result
      onChange?()
    }
    return result.serialized()
  }

  private func read(_ name: String, _ params: JSON, _ id: String) async throws -> String {
    var request = try scoped(params, id)
    if request["tabId"]?.string == nil, let owner = run(id)?.ownerTabId {
      request["tabId"] = .string(owner)
    }
    let tab = try? app?.resolveTab(.object(request))
    let step = beginStep(
      id, kind: name, text: name == "observe" ? "Look at the page" : "Read the page", tab: tab?.id)
    do {
      let result = try await call(name, request)
      endStep(id, step, state: "done", reason: nil)
      used(tab?.id, run: id)
      return name == "observe"
        ? Self.compact(result) : Self.clip(result["content"]?.string ?? "", 12_000)
    } catch {
      endStep(id, step, state: "failed", reason: (error as? RPCError)?.message)
      throw error
    }
  }

  private func requestControl(_ params: JSON, _ id: String) async throws -> String {
    let request = try scoped(params, id)
    var result = try await call("request_control", request)
    guard result["state"]?.string == "pending", let approval = result["approvalId"]?.string,
      let tab = try? app?.resolveTab(.object(request))
    else { return result.serialized() }
    await wait(id) { self.app?.approvals.item(approval) != nil }
    var fields = result.object ?? [:]
    fields["state"] = tab.control.controller == .agent(session(id)) ? "granted" : "denied"
    result = .object(fields)
    return result.serialized()
  }

  private func status(_ params: JSON, _ id: String) async throws -> String {
    let row = try await call("action_status", withSession(params, id))
    guard row["sessionId"]?.string == session(id) else { throw RPCError.failure("no such action") }
    return Self.row(row, settle: nil)
  }

  private func act(_ params: JSON, _ id: String) async throws -> String {
    var request = try scoped(params, id)
    let tab = request["observationId"]?.string.flatMap { seen in
      app?.tabs.first { $0.observation(id: seen) != nil }
    }
    if let tab { try own(tab.id, run: id) }
    actCount += 1
    request["clientActionId"] = .string("\(session(id))-\(actCount)")
    let words = app.flatMap { Self.words($0, request) } ?? "Act on the page"
    let step = beginStep(id, kind: "act", text: words, tab: tab?.id)
    do {
      let first = try await call("act", request)
      let rowId = first["id"]?.int
      if let rowId { acts[id, default: []].append(rowId) }
      let settle = first["settle"]
      var row = first
      // A sensitive act waits for a person; the run waits with it, and the model is told how it ended.
      if let rowId, ["quoted", "pending"].contains(row["state"]?.string) {
        let waiting = row["state"]?.string == "quoted"
        if waiting { advance(id, to: .waitingApproval) }
        await wait(id) {
          row = (try? await self.call("action_status", ["actionId": .number(Double(rowId))])) ?? row
          return ["quoted", "pending"].contains(row["state"]?.string)
        }
        if waiting { advance(id, to: .running) }
      }
      endStep(
        id, step, state: row["state"]?.string ?? "failed", reason: row["reason"]?.string,
        action: row["id"]?.int)
      used(tab?.id ?? row["tabId"]?.string, run: id)
      return Self.row(row, settle: settle)
    } catch {
      endStep(id, step, state: "failed", reason: (error as? RPCError)?.message)
      throw error
    }
  }

  /// Polls until `pending` goes false, the run ends, or the task is cancelled.
  private func wait(_ id: String, while pending: () async -> Bool) async {
    while run(id)?.state.isInProgress == true, await pending() {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  // MARK: Steps and trail

  private func beginStep(_ id: String, kind: String, text: String, tab: String?) -> Int? {
    let step = book.addStep(
      run: id, kind: kind, text: text, tabId: tab, now: Date().timeIntervalSince1970)
    onChange?()
    return step
  }

  private func endStep(
    _ id: String, _ step: Int?, state: String, reason: String?, action: Int? = nil
  ) {
    guard let step else { return }
    book.finishStep(
      run: id, step: step, state: state, reason: reason, actionId: action,
      now: Date().timeIntervalSince1970)
    onChange?()
  }

  /// The trail edge from the run's page to a page it has now used: only after a call on it.
  private func used(_ tabId: String?, run id: String) {
    guard let tabId, let owner = run(id)?.ownerTabId, let canvas = app?.canvas else { return }
    var added = false
    canvas.edit { graph in
      added = graph.museUsed(run: id, ownerTab: owner, usedTab: tabId)
      return added
    }
    if added { Log.info(.runs, "trail run=\(id) from=\(owner) to=\(tabId)") }
  }

  private static func words(_ app: AppController, _ fields: [String: JSON]) -> String? {
    guard let request = try? ActRequest(.object(fields)) else { return nil }
    var name = fields["instruction"]?.string
    if name == nil, let ref = fields["ref"]?.int, let observation = fields["observationId"]?.string
    {
      let element = app.tabs.lazy.compactMap { $0.observation(id: observation) }.first?
        .elements.first { $0.ref == ref }
      name = element?.name
    }
    return Actions.describe(request, name: name, reveal: false)
  }

  // MARK: What the model reads back

  private static func clip(_ text: String, _ limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + " … (cut)"
  }

  private static func compact(_ observation: JSON) -> String {
    let elements = (observation["elements"]?.array ?? []).prefix(200).map { element -> JSON in
      var fields: [String: JSON] = ["ref": element["ref"] ?? .null]
      for key in ["role", "name", "value"] {
        if let text = element[key]?.string, !text.isEmpty { fields[key] = .string(clip(text, 80)) }
      }
      if element["sensitive"]?.bool == true { fields["sensitive"] = true }
      return .object(fields)
    }
    return JSON.object([
      "observationId": observation["id"] ?? .null, "tabId": observation["tabId"] ?? .null,
      "url": observation["url"] ?? .null, "title": observation["title"] ?? .null,
      "elements": .array(elements),
    ]).serialized()
  }

  /// A journal row as the model should read it, with the settle outcome when the act just ran.
  private static func row(_ row: JSON, settle: JSON?) -> String {
    var fields: [String: JSON] = [:]
    for key in ["id", "state", "reason", "kind", "target", "rung", "domVerdict", "modelVerdict"] {
      if let value = row[key] { fields[key == "id" ? "actionId" : key] = value }
    }
    if let settle, settle != .null { fields["settle"] = settle }
    return JSON.object(fields).serialized()
  }

  // MARK: Socket

  static func json(_ run: Run, session: String) -> JSON {
    [
      "runId": .string(run.id), "sessionId": .string(session),
      "origin": .string(run.origin.rawValue),
      "prompt": .string(run.prompt), "tabId": run.ownerTabId.map { .string($0) } ?? .null,
      "state": .string(run.state.rawValue), "reason": run.reason.map { .string($0) } ?? .null,
      "costUSD": .number(run.costUSD),
      "steps": .array(
        run.steps.map { step in
          [
            "id": .number(Double(step.id)), "kind": .string(step.kind), "text": .string(step.text),
            "tabId": step.tabId.map { .string($0) } ?? .null, "state": .string(step.state),
            "reason": step.reason.map { .string($0) } ?? .null,
            "actionId": step.actionId.map { .number(Double($0)) } ?? .null,
            "startedAt": .number(step.startedAt),
            "endedAt": step.endedAt.map { .number($0) } ?? .null,
          ]
        }),
    ]
  }
}

@MainActor
func registerRunMethods(_ dispatcher: RPCDispatcher, controller: AppController) {
  let runs = controller.runs
  runs.attach(app: controller, dispatcher: dispatcher)

  func json(_ run: Run) -> JSON { RunController.json(run, session: runs.session(run.id)) }

  dispatcher.register("run.start") { params in
    guard let origin = params["origin"]?.string.flatMap(RunOrigin.init(rawValue:)) else {
      throw RPCError.invalidParams("origin (mac or phone) required")
    }
    let tabId: String?
    switch params["tabId"] {
    case nil, .some(.null): tabId = nil
    case .some(.string(let id)): tabId = id
    default: throw RPCError.invalidParams("tabId must be a string")
    }
    if let tabId, controller.tab(id: tabId) == nil {
      throw RPCError.failure("unknown tab \(tabId)")
    }
    let remote = origin == .phone ? params["remoteSession"]?.string : nil
    if let remote, !controller.events.isOpen(remote) { throw RPCError.failure("no-session") }
    guard
      let run = runs.start(
        prompt: try params.requireString("prompt"), origin: origin, tabId: tabId,
        remoteSession: remote)
    else { throw RPCError.invalidParams("prompt must not be blank") }
    return json(run)
  }

  /// A phone's call names its session: it must be open and the run must be the phone's own.
  func runId(_ params: JSON) throws -> String {
    let id = try params.requireString("runId")
    if let session = params["remoteSession"]?.string {
      guard controller.events.isOpen(session) else { throw RPCError.failure("no-session") }
      guard runs.isOwned(id, by: session) else { throw RPCError.failure("no such run \(id)") }
    }
    return id
  }

  dispatcher.register("run.takeover") { params in json(try runs.takeOver(try runId(params))) }

  dispatcher.register("run.stop") { params in json(try runs.stop(try runId(params))) }

  dispatcher.register("run.list") { _ in
    ["runs": .array(runs.runs.map(json))]
  }
}
