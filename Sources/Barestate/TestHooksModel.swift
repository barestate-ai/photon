import BarestateCore
import Foundation

private final class DeltaCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func add() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

/// `test.holdModel {on}` makes runs wait before their next model call while on, so a started run
/// stays `pending` or `running` without spending anything.
///
/// `test.breakChain {on}` makes the next chained loop request name a fabricated response id
/// (`resp_` and 24 hex digits) and then turns itself off. The real provider answers it with its
/// own 400; the hook never supplies model output.
///
/// `test.runState {runId, state, reason?}` and `test.runStep {runId, text, tabId?, state?, reason?}`
/// put a run in a state or give it a journal-like step without the model, for the states and
/// failures a live model cannot be made to produce on demand (waiting-approval, needs-human).
///
/// `test.runTool {runId, name, arguments}` runs one tool call for a run through the entry the agent
/// loop uses and returns its output string, so tool boundaries are tested with no model in the loop.
///
/// `test.networkPath {satisfied}` stands for the system losing or regaining its network path.
///
/// `test.runCost {usd}` puts that much spend, as if already made, on the next run to start
/// (VAL-MODEL-005: a run past the cap without paying for it).
///
/// `test.model.call {prompt, source?, computer?, image?, stream?, maxOutputTokens?}` sends one
/// request through the real client (routing, cap, spend entry) and reports the answer without
/// the key. A model fault comes back as an error whose message starts with its code.
@MainActor
func registerModelHooks(_ dispatcher: RPCDispatcher, controller: AppController) {
  dispatcher.register("test.holdModel") { params in
    controller.runs.holdModel = params["on"]?.bool ?? true
    return ["on": .bool(controller.runs.holdModel)]
  }

  dispatcher.register("test.breakChain") { params in
    controller.runs.breakChain = params["on"]?.bool ?? true
    return ["on": .bool(controller.runs.breakChain)]
  }

  dispatcher.register("test.runTool") { params in
    let id = try params.requireString("runId")
    guard controller.runs.run(id) != nil else { throw RPCError.failure("no such run \(id)") }
    let call = FunctionCall(
      callId: "test", name: try params.requireString("name"),
      arguments: (params["arguments"] ?? [:]).serialized())
    return ["output": .string(await controller.runs.execute(call, run: id))]
  }

  dispatcher.register("test.networkPath") { params in
    controller.network.satisfied = params["satisfied"]?.bool ?? true
    return ["satisfied": .bool(controller.network.satisfied)]
  }

  dispatcher.register("test.runCost") { params in
    guard let usd = params["usd"]?.number, usd >= 0 else {
      throw RPCError.invalidParams("usd (number >= 0) required")
    }
    controller.runs.nextRunSeedUSD = usd
    return ["usd": .number(usd)]
  }

  dispatcher.register("test.runState") { params in
    let id = try params.requireString("runId")
    guard let state = params["state"]?.string.flatMap(RunState.init(rawValue:)) else {
      throw RPCError.invalidParams("state (a run state) required")
    }
    guard controller.runs.force(id, to: state, reason: params["reason"]?.string) else {
      throw RPCError.failure("run \(id) cannot move to \(state.rawValue)")
    }
    return RunController.json(controller.runs.run(id)!, session: controller.runs.session(id))
  }

  dispatcher.register("test.runStep") { params in
    let id = try params.requireString("runId")
    guard
      controller.runs.record(
        id, text: try params.requireString("text"), tab: params["tabId"]?.string,
        state: params["state"]?.string, reason: params["reason"]?.string)
    else { throw RPCError.failure("no such run \(id)") }
    return RunController.json(controller.runs.run(id)!, session: controller.runs.session(id))
  }

  dispatcher.register("test.model.call") { params in
    guard let prompt = params["prompt"]?.string else {
      throw RPCError.invalidParams("prompt (string) required")
    }
    var parts: [JSON] = [["type": "input_text", "text": .string(prompt)]]
    if let image = params["image"]?.string {
      parts.append(["type": "input_image", "image_url": .string(image)])
    }
    var request = ModelRequest(
      input: [["role": "user", "content": .array(parts)]],
      computer: params["computer"]?.bool ?? false,
      maxOutputTokens: params["maxOutputTokens"]?.int ?? 400)
    let deltas = DeltaCount()
    if params["stream"]?.bool ?? false { request.onDelta = { _ in deltas.add() } }
    do {
      let response = try await controller.modelClient().call(
        request, source: params["source"]?.string ?? "test.model.call")
      return [
        "text": .string(response.text), "model": .string(response.model),
        "endpoint": .string(response.endpoint), "usd": .number(response.usd),
        "inputTokens": .number(Double(response.usage.input)),
        "outputTokens": .number(Double(response.usage.output)),
        "cachedTokens": .number(Double(response.usage.cached)),
        "requestId": response.requestId.map { .string($0) } ?? .null,
        "deltas": .number(Double(deltas.value)),
        "computerCall": .bool(response.computerCall != nil),
        "functionCalls": .number(Double(response.functionCalls.count)),
      ]
    } catch let error as ModelError {
      throw RPCError(code: -32001, message: "\(error.code): \(error)")
    }
  }
}
