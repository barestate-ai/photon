import BarestateCore
import Foundation
import Testing

/// Stands in for the network only: the loop and the real client run against canned replies.
private final class Wire: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [(body: String, status: Int)]
  private(set) var bodies: [JSON] = []

  init(_ replies: [String]) { queue = replies.map { ($0, 200) } }

  /// Replies with the status each carries: the one fault a test cannot ask the real API for on
  /// demand beyond the lost chain (a refused replay).
  init(steps: [(String, Int)]) { queue = steps.map { (body: $0.0, status: $0.1) } }

  var transport: ModelTransport {
    { [self] request, _ in
      let (body, status) = lock.withLock { () -> (String, Int) in
        bodies.append(JSON.parse(request.httpBody ?? Data()) ?? .null)
        return queue.isEmpty ? ("{}", 500) : queue.removeFirst()
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (Data(body.utf8), response)
    }
  }
}

private func client(_ wire: Wire, ledger: SpendLedger? = nil) -> ModelClient {
  ModelClient(
    environment: ["MODEL_API_KEY": "sk-test"], envFile: nil,
    ledger: ledger ?? SpendLedger(path: NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"),
    transport: wire.transport)
}

private func reply(_ id: String, calls: [(String, String)] = [], text: String = "") -> String {
  var output = calls.map {
    #"{"type":"function_call","call_id":"call_\#($0.0)","name":"\#($0.1)","arguments":"{}"}"#
  }
  if !text.isEmpty {
    output.append(
      #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}"#
    )
  }
  return """
    {"id":"\(id)","model":"muse-spark-1.3","output":[\(output.joined(separator: ","))],
    "usage":{"input_tokens":10,"output_tokens":5}}
    """
}

@MainActor
private final class Harness {
  var live = true
  var withinCap = true
  var executed: [String] = []
  var capChecks = 0

  var replayed: [Int] = []

  func run(_ wire: Wire, ledger: SpendLedger? = nil) async -> AgentLoop.End {
    let model = client(wire, ledger: ledger)
    return await AgentLoop.run(
      prompt: "do it",
      live: { self.live },
      withinCap: {
        self.capChecks += 1
        return self.withinCap
      },
      replayed: { self.replayed.append($0) },
      model: { try await model.call($0, source: "loop") },
      tool: { call in
        self.executed.append(call.name)
        return "ok \(call.name)"
      })
  }
}

private let reasoningOnly = """
  {"id":"resp_1","model":"muse-spark-1.3","status":"incomplete",
  "incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"reasoning"}],
  "usage":{"input_tokens":10,"output_tokens":5}}
  """

private let brokenCall = """
  {"id":"resp_1","model":"muse-spark-1.3","status":"completed",
  "output":[{"type":"function_call","call_id":"call_1","name":"act"}],
  "usage":{"input_tokens":10,"output_tokens":5}}
  """

private let lostReference = """
  {"error":{"code":null,"message":"referenced response not found or expired","param":null,\
  "type":"invalid_request_error"}}
  """

private func recorded(_ id: String, output: String) -> String {
  """
  {"id":"\(id)","model":"muse-spark-1.3","status":"completed","output":\(output),
  "usage":{"input_tokens":10,"output_tokens":5}}
  """
}

@MainActor
struct AgentLoopTests {
  @Test func aToolCallIsRunAndItsResultGoesBackOnTheSameConversation() async {
    let wire = Wire([
      reply("resp_1", calls: [("1", "observe")]), reply("resp_2", text: "All done"),
    ])
    let harness = Harness()
    let end = await harness.run(wire)
    #expect(end == .ended)
    #expect(harness.executed == ["observe"])
    #expect(wire.bodies.count == 2)
    let first = wire.bodies[0]
    #expect(first["model"] == "muse-spark-1.3")
    #expect(first["instructions"]?.string?.isEmpty == false)
    let names = first["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
    #expect(
      Set(names) == [
        "tabs", "observe", "extract", "action_status", "open_tab", "request_control", "handoff",
        "act",
      ])
    #expect(first["tools"]?.array?.contains { $0["type"] == "computer" } == false)
    let second = wire.bodies[1]
    #expect(second["previous_response_id"] == "resp_1")
    #expect(second["tools"] == first["tools"])
    let output = second["input"]?.array?.first
    #expect(output?["type"] == "function_call_output" && output?["call_id"] == "call_1")
    #expect(output?["output"] == "ok observe")
  }

  @Test func severalCallsInOneReplyAreAllAnsweredInOrder() async {
    let wire = Wire([
      reply("resp_1", calls: [("a", "tabs"), ("b", "observe")]), reply("resp_2", text: "done"),
    ])
    let harness = Harness()
    #expect(await harness.run(wire) == .ended)
    #expect(harness.executed == ["tabs", "observe"])
    let outputs = wire.bodies[1]["input"]?.array?.compactMap { $0["call_id"]?.string }
    #expect(outputs == ["call_a", "call_b"])
  }

  @Test func theCapIsCheckedBeforeEveryModelCallAndStopsTheLoopWithoutAnother() async {
    let wire = Wire([reply("resp_1", calls: [("1", "observe")]), reply("resp_2", text: "x")])
    let harness = Harness()
    let model = client(wire)
    let end = await AgentLoop.run(
      prompt: "go", live: { true },
      withinCap: {
        harness.capChecks += 1
        return harness.capChecks < 3
      },
      model: { try await model.call($0, source: "loop") },
      tool: { _ in "ok" })
    #expect(end == .failed("run-cap"))
    #expect(wire.bodies.count == 1)
    #expect(harness.capChecks == 3)
  }

  @Test func aCallThatTakesTheRunOverTheCapIsNotFollowedByItsTools() async {
    let wire = Wire([reply("resp_1", calls: [("1", "act")]), reply("resp_2", text: "x")])
    let harness = Harness()
    harness.withinCap = true
    let model = client(wire)
    let end = await AgentLoop.run(
      prompt: "go", live: { true },
      withinCap: {
        harness.capChecks += 1
        return harness.capChecks < 2
      },
      model: { try await model.call($0, source: "loop") },
      tool: { _ in
        harness.executed.append("act")
        return "ok"
      })
    #expect(end == .failed("run-cap"))
    #expect(harness.executed.isEmpty)
    #expect(wire.bodies.count == 1)
  }

  @Test func aRunStoppedMidCallRunsNoToolAndMakesNoFurtherCall() async {
    let wire = Wire([reply("resp_1", calls: [("1", "act")]), reply("resp_2", text: "x")])
    let harness = Harness()
    let model = client(wire)
    let end = await AgentLoop.run(
      prompt: "go", live: { harness.live }, withinCap: { true },
      model: {
        let response = try await model.call($0, source: "loop")
        harness.live = false
        return response
      }, tool: { _ in "never" })
    #expect(end == .stopped)
    #expect(wire.bodies.count == 1)
  }

  @Test func aStopBetweenToolsStopsBeforeTheNextOne() async {
    let wire = Wire([reply("resp_1", calls: [("a", "act"), ("b", "act")])])
    let harness = Harness()
    let model = client(wire)
    let end = await AgentLoop.run(
      prompt: "go", live: { harness.live }, withinCap: { true },
      model: { try await model.call($0, source: "loop") },
      tool: { _ in
        harness.executed.append("act")
        harness.live = false
        return "ok"
      })
    #expect(end == .stopped)
    #expect(harness.executed == ["act"])
  }

  @Test func aModelFailureEndsTheRunWithTheProvidersWordsNotTheKeys() async {
    let wire = Wire([])
    let harness = Harness()
    let end = await harness.run(wire)
    guard case .failed(let reason) = end else {
      Issue.record("expected failed, got \(end)")
      return
    }
    #expect(reason.contains("server") && !reason.contains("sk-test"))
  }

  @Test func aLoopThatNeverStopsEndsAtTheTurnLimit() async {
    let wire = Wire(
      (0..<AgentLoop.maxTurns + 1).map { reply("resp_\($0)", calls: [("c\($0)", "tabs")]) })
    let harness = Harness()
    #expect(await harness.run(wire) == .failed("turn-limit"))
    #expect(wire.bodies.count == AgentLoop.maxTurns)
  }

  @Test func theModelStoppingBeforeAnyToolIsAnEndedRun() async {
    let wire = Wire([reply("resp_1", text: "Nothing to do")])
    let harness = Harness()
    #expect(await harness.run(wire) == .ended)
    #expect(harness.executed.isEmpty)
  }

  @Test(arguments: [reasoningOnly, brokenCall])
  func anIncompleteTurnOrABrokenCallNeverEndsTheRunAndIsBilledOnce(body: String) async throws {
    let path = NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
    let ledger = SpendLedger(path: path)
    let wire = Wire([body, reply("resp_2", text: "never asked")])
    let harness = Harness()
    #expect(await harness.run(wire, ledger: ledger) == .failed("model response incomplete"))
    #expect(harness.executed.isEmpty)
    #expect(wire.bodies.count == 1)
    let spent = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(spent?["entries"]?.array?.count == 1)
  }

  @Test func aLostChainedResponseResendsTheTurnOnceWithTheWholeTranscriptAndChainingResumes()
    async throws
  {
    let path = NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
    let wire = Wire(steps: [
      (recorded("resp_1", output: recordedTurnOne), 200),
      (recorded("resp_2", output: recordedTurnTwo), 200),
      (lostReference, 400),
      (recorded("resp_4", output: recordedTurnTwo), 200),
      (reply("resp_5", text: "All done"), 200),
    ])
    let harness = Harness()
    #expect(await harness.run(wire, ledger: SpendLedger(path: path)) == .ended)
    #expect(wire.bodies.count == 5)
    #expect(harness.replayed == [3])

    let lost = wire.bodies[2]
    let replay = wire.bodies[3]
    #expect(lost["previous_response_id"] == "resp_2")
    #expect(replay["previous_response_id"] == nil)
    #expect(replay["instructions"] == lost["instructions"] && replay["tools"] == lost["tools"])
    #expect(replay["max_output_tokens"] == lost["max_output_tokens"])
    let kinds = replay["input"]?.array?.map { $0["type"]?.string ?? "user" }
    #expect(
      kinds == [
        "user", "message", "function_call", "function_call_output", "function_call",
        "function_call_output",
      ])
    #expect(replay["input"]?[1]?["phase"] == "commentary")
    #expect(wire.bodies[4]["previous_response_id"] == "resp_4")
    #expect(wire.bodies[4]["input"]?.array?.count == 1)

    let spent = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(spent?["entries"]?.array?.count == 4)
  }

  @Test func aSecondRejectionOfTheReplayEndsTheRunWithTheProvidersWords() async {
    let wire = Wire(steps: [
      (recorded("resp_1", output: recordedTurnOne), 200), (lostReference, 400),
      (lostReference, 400), (reply("resp_9", text: "never asked"), 200),
    ])
    let harness = Harness()
    let end = await harness.run(wire)
    #expect(
      end
        == .failed(
          "model rejected the request (400): referenced response not found or expired"))
    #expect(wire.bodies.count == 3)
    #expect(harness.replayed == [2])
  }

  @Test func aFirstTurnOrAnotherRejectionIsNotReplayed() async {
    let first = Wire(steps: [(lostReference, 400)])
    let harness = Harness()
    guard case .failed = await harness.run(first) else {
      Issue.record("expected failed")
      return
    }
    #expect(first.bodies.count == 1)
    let other = Wire(steps: [
      (recorded("resp_1", output: recordedTurnOne), 200),
      (#"{"error":{"message":"max_output_tokens too small"}}"#, 400),
    ])
    guard case .failed = await harness.run(other) else {
      Issue.record("expected failed")
      return
    }
    #expect(other.bodies.count == 2)
    #expect(harness.replayed.isEmpty)
  }

  @Test func aStopDuringALostChainedCallSendsNoReplay() async {
    let wire = Wire(steps: [
      (recorded("resp_1", output: recordedTurnOne), 200), (lostReference, 400),
      (reply("resp_3", text: "never asked"), 200),
    ])
    let harness = Harness()
    let model = client(wire)
    let end = await AgentLoop.run(
      prompt: "do it", live: { harness.live }, withinCap: { true },
      model: { request in
        do {
          return try await model.call(request, source: "loop")
        } catch {
          harness.live = false
          throw error
        }
      },
      tool: { _ in "ok" })
    #expect(end == .stopped)
    #expect(wire.bodies.count == 2)
  }

  @Test func aCompletedReplyWithoutToolsOrProseStillEnds() async {
    let body = """
      {"id":"resp_1","model":"muse-spark-1.3","status":"completed","output":[{"type":"reasoning"}],
      "usage":{"input_tokens":10,"output_tokens":5}}
      """
    #expect(await Harness().run(Wire([body])) == .ended)
  }
}
