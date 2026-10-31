import BarestateCore
import Foundation
import Testing

/// Stands in for the network only: records every request and answers with canned bytes or a
/// transport error. Real API behavior is checked by the live e2e test, not here.
private final class Wire: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [URLRequest] = []
  var reply: @Sendable (URLRequest) throws -> (Int, String) = { _ in (200, "{}") }

  var requests: [URLRequest] { lock.withLock { seen } }

  var transport: ModelTransport {
    { [self] request, onLine in
      lock.withLock { seen.append(request) }
      let (status, body) = try reply(request)
      for line in body.split(separator: "\n") { onLine?(String(line)) }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["x-request-id": "req-1"])!
      return (Data(body.utf8), response)
    }
  }

  func body(_ index: Int = 0) -> JSON {
    JSON.parse(requests[index].httpBody ?? Data()) ?? .null
  }
}

private let key = "sk-test-secret-1234"

private let metaReply = """
  {"id":"resp_1","model":"muse-spark-1.3","output":[
  {"type":"reasoning"},
  {"type":"message","role":"assistant","content":[{"type":"output_text","text":"pong"}]},
  {"type":"function_call","call_id":"call_1","name":"observe","arguments":"{\\"max_nodes\\":5}"}],
  "usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40}}}
  """

private let basetenReply = """
  {"id":"chat_1","model":"meta-models/muse-spark-open","choices":[{"message":{"role":"assistant",
  "content":"pong","tool_calls":[{"id":"call_9","type":"function",
  "function":{"name":"observe","arguments":"{}"}}]}}],
  "usage":{"prompt_tokens":50,"completion_tokens":10}}
  """

private func ledgerPath() -> String {
  NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
}

private func client(
  _ wire: Wire, environment: [String: String] = ["MODEL_API_KEY": key], envFile: String? = nil,
  keychain: @escaping @Sendable () -> String? = { nil }, ledger: String = ledgerPath()
) -> ModelClient {
  ModelClient(
    environment: environment, envFile: envFile, keychain: keychain,
    ledger: SpendLedger(path: ledger), transport: wire.transport)
}

private func ask(computer: Bool = false) -> ModelRequest {
  ModelRequest(
    instructions: "be brief",
    input: [
      [
        "role": "user",
        "content": [
          ["type": "input_text", "text": "hi"],
          ["type": "input_image", "image_url": "data:image/png;base64,AAAA"],
        ],
      ]
    ],
    tools: [
      [
        "type": "function", "name": "observe", "description": "look",
        "parameters": ["type": "object", "properties": [:], "required": []],
      ]
    ],
    computer: computer)
}

struct ModelClientTests {
  @Test func metaGetsAResponsesRequestWithBearerFunctionToolsAndImage() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    let response = try await client(wire).call(ask(), source: "t")
    let request = try #require(wire.requests.first)
    #expect(request.url?.absoluteString == "https://api.meta.ai/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
    let body = wire.body()
    #expect(body["model"]?.string == "muse-spark-1.3")
    #expect(body["instructions"]?.string == "be brief")
    #expect(body["tools"]?[0]?["name"]?.string == "observe")
    #expect(body["tools"]?.array?.count == 1)
    #expect(body["input"]?[0]?["content"]?[1]?["type"]?.string == "input_image")
    #expect(response.text == "pong")
    #expect(response.functionCalls.map(\.callId) == ["call_1"])
    #expect(response.functionCalls.map(\.arguments) == [#"{"max_nodes":5}"#])
    #expect(response.requestId == "req-1")
  }

  @Test func theComputerToolRidesTheSparkRequest() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    _ = try await client(wire).call(ask(computer: true), source: "t")
    let tools = try #require(wire.body()["tools"]?.array)
    #expect(tools.last?["type"]?.string == "computer")
  }

  @Test func aJSONSchemaRequestUsesStrictTextFormat() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    var request = ask()
    request.schema = ("verdict", ["type": "object"])
    _ = try await client(wire).call(request, source: "t")
    let format = wire.body()["text"]?["format"]
    #expect(format?["type"]?.string == "json_schema")
    #expect(format?["name"]?.string == "verdict")
    #expect(format?["strict"]?.bool == true)
    #expect(format?["schema"]?["type"]?.string == "object")
  }

  @Test func wonderNeverGetsTheComputerTool() async throws {
    let env = ["MODEL_API_KEY": key, "BARESTATE_MODEL": "muse-wonder-1.0"]
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    _ = try await client(wire, environment: env).call(ask(computer: true), source: "t")
    #expect(wire.body()["model"]?.string == "muse-spark-1.3")
    wire.reply = { _ in
      (200, metaReply.replacingOccurrences(of: "muse-spark-1.3", with: "muse-wonder-1.0"))
    }
    _ = try await client(wire, environment: env).call(ask(), source: "t")
    #expect(wire.body(1)["model"]?.string == "muse-wonder-1.0")
    #expect(wire.body(1)["tools"]?.array?.contains { $0["type"]?.string == "computer" } == false)
  }

  @Test func theOverrideSelectsAnotherModel() {
    #expect(
      ModelRouter.model(computer: false, override: "muse-spark-1.3-contributor")
        == "muse-spark-1.3-contributor")
    #expect(
      ModelRouter.model(computer: true, override: "muse-spark-1.3-contributor")
        == "muse-spark-1.3-contributor")
    #expect(ModelRouter.model(computer: true, override: nil) == "muse-spark-1.3")
    #expect(ModelRouter.model(computer: true, override: "  ") == "muse-spark-1.3")
    #expect(ModelRouter.model(computer: true, override: "muse-wonder-1.0") == "muse-spark-1.3")
  }

  @Test func aModelThatIsNotTheRequestedOneIsMalformed() async {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply.replacingOccurrences(of: "muse-spark-1.3", with: "other")) }
    await #expect(throws: ModelError.self) { try await client(wire).call(ask(), source: "t") }
  }

  @Test func basetenIsChosenByItsKeyWithChatCompletionsShape() async throws {
    let env = ["BASETEN_API_KEY": "bt-dummy", "BARESTATE_BASETEN_URL": "http://127.0.0.1:47881/v1"]
    let wire = Wire()
    wire.reply = { _ in (200, basetenReply) }
    var request = ask()
    request.input.append([
      "type": "function_call", "call_id": "c1", "name": "observe", "arguments": "{}",
    ])
    request.input.append(["type": "function_call_output", "call_id": "c1", "output": "ok"])
    let response = try await client(wire, environment: env).call(request, source: "t")
    let sent = try #require(wire.requests.first)
    #expect(sent.url?.absoluteString == "http://127.0.0.1:47881/v1/chat/completions")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer bt-dummy")
    let body = wire.body()
    #expect(body["model"]?.string == "meta-models/muse-spark-open")
    #expect(body["tools"]?[0]?["type"]?.string == "function")
    #expect(body["tools"]?[0]?["function"]?["name"]?.string == "observe")
    #expect(body["tools"]?.array?.contains { $0["type"]?.string == "computer" } == false)
    let messages = try #require(body["messages"]?.array)
    #expect(messages[0]["role"]?.string == "system")
    #expect(messages[1]["content"]?[0]?["type"]?.string == "text")
    #expect(
      messages[1]["content"]?[1]?["image_url"]?["url"]?.string == "data:image/png;base64,AAAA")
    #expect(messages[2]["tool_calls"]?[0]?["id"]?.string == "c1")
    #expect(messages[3]["role"]?.string == "tool")
    #expect(messages[3]["tool_call_id"]?.string == "c1")
    #expect(response.text == "pong")
    #expect(response.functionCalls.first?.callId == "call_9")
    #expect(response.usage == ModelUsage(input: 50, output: 10, cached: 0))
  }

  @Test func aBasetenReplyCutOffByLengthIsIncomplete() async throws {
    let env = ["BASETEN_API_KEY": "bt-dummy", "BARESTATE_BASETEN_URL": "http://127.0.0.1:47881/v1"]
    let wire = Wire()
    wire.reply = { _ in
      (
        200,
        basetenReply.replacingOccurrences(
          of: #""message":"#, with: #""finish_reason":"length","message":"#)
      )
    }
    let response = try await client(wire, environment: env).call(ask(), source: "t")
    #expect(response.incompleteReason == "length")
    wire.reply = { _ in (200, basetenReply) }
    #expect(
      try await client(wire, environment: env).call(ask(), source: "t").incompleteReason == nil)
  }

  @Test func aBasetenToolCallWithoutArgumentsIsIncompleteAndStillBilled() async throws {
    let env = ["BASETEN_API_KEY": "bt-dummy", "BARESTATE_BASETEN_URL": "http://127.0.0.1:47881/v1"]
    let path = ledgerPath()
    let wire = Wire()
    wire.reply = { _ in
      (200, basetenReply.replacingOccurrences(of: #","arguments":"{}""#, with: ""))
    }
    let response = try await client(wire, environment: env, ledger: path).call(ask(), source: "t")
    #expect(response.incompleteReason == "malformed function call")
    #expect(response.functionCalls.isEmpty)
    let spent = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(spent?["entries"]?.array?.count == 1)
  }

  @Test func basetenRefusesTheComputerToolWithoutANetworkCall() async {
    let wire = Wire()
    let env = ["BASETEN_API_KEY": "bt-dummy"]
    await #expect(throws: ModelError.self) {
      try await client(wire, environment: env).call(ask(computer: true), source: "t")
    }
    #expect(wire.requests.isEmpty)
  }

  @Test func withoutTheBasetenKeyMetaIsChosen() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    _ = try await client(wire).call(ask(), source: "t")
    #expect(wire.requests.first?.url?.path == "/v1/responses")
  }

  @Test func noKeyIsATypedErrorWithoutANetworkCall() async {
    let wire = Wire()
    await #expect(throws: ModelError.noKey) {
      try await client(wire, environment: [:]).call(ask(), source: "t")
    }
    #expect(wire.requests.isEmpty)
  }

  @Test func theKeychainKeyIsUsedLast() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    _ = try await client(wire, environment: [:], keychain: { "kc-key" }).call(ask(), source: "t")
    #expect(wire.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer kc-key")
  }

  @Test func aSuccessfulCallAppendsOneSpendEntryAndTheKeyIsNotInIt() async throws {
    let path = ledgerPath()
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    let response = try await client(wire, ledger: path).call(ask(), source: "unit:spend")
    // (100 - 40) * 1.25 + 40 * 0.15 + 20 * 4.25 = 166 micro-dollars
    #expect(response.usd == 0.000166)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let file = JSON.parse(Data(text.utf8))
    #expect(file?["entries"]?.array?.count == 1)
    #expect(file?["entries"]?[0]?["source"]?.string == "unit:spend")
    #expect(file?["entries"]?[0]?["endpoint"]?.string == "/responses")
    #expect(file?["total_usd"]?.number == 0.000166)
    #expect(!text.contains(key))
  }

  @Test func atTheCapNoRequestIsSentAndTheLedgerIsUnchanged() async throws {
    let path = ledgerPath()
    let original = #"{"cap_usd":40,"per_run_cap_usd":3,"total_usd":40,"entries":[]}"#
    try original.write(toFile: path, atomically: true, encoding: .utf8)
    let wire = Wire()
    await #expect(throws: ModelError.capReached(total: 40)) {
      try await client(wire, ledger: path).call(ask(), source: "t")
    }
    #expect(wire.requests.isEmpty)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
  }

  @Test func justBelowTheCapIsAllowed() async throws {
    let path = ledgerPath()
    try #"{"total_usd":39.99,"entries":[]}"#.write(toFile: path, atomically: true, encoding: .utf8)
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    _ = try await client(wire, ledger: path).call(ask(), source: "t")
    #expect(wire.requests.count == 1)
  }

  @Test(arguments: [
    ("offline", ModelError.unreachable),
    ("timeout", ModelError.timeout),
    ("503", ModelError.server(status: 503)),
    ("429", ModelError.server(status: 429)),
    ("bad-json", ModelError.malformed("body is not JSON")),
    ("no-output", ModelError.malformed("response has no output or usage")),
    ("400", ModelError.rejected(status: 400, message: "bad request")),
    ("negative-usage", ModelError.malformed("impossible token counts")),
    ("cached-over-input", ModelError.malformed("impossible token counts")),
  ])
  func faultsAreTypedAndNeverBillOrLeakTheKey(fault: String, expected: ModelError) async throws {
    let path = ledgerPath()
    let wire = Wire()
    wire.reply = { _ in
      switch fault {
      case "offline": throw URLError(.notConnectedToInternet)
      case "timeout": throw URLError(.timedOut)
      case "503": return (503, "<html>overloaded</html>")
      case "429": return (429, #"{"error":{"message":"slow down"}}"#)
      case "bad-json": return (200, "<html>")
      case "no-output": return (200, #"{"id":"r","model":"muse-spark-1.3"}"#)
      case "negative-usage":
        return (
          200,
          metaReply.replacingOccurrences(of: #""output_tokens":20"#, with: #""output_tokens":-20"#)
        )
      case "cached-over-input":
        return (
          200,
          metaReply.replacingOccurrences(of: #""cached_tokens":40"#, with: #""cached_tokens":400"#)
        )
      default: return (400, #"{"error":{"message":"bad request"}}"#)
      }
    }
    do {
      _ = try await client(wire, ledger: path).call(ask(), source: "t")
      Issue.record("expected \(expected)")
    } catch let error as ModelError {
      #expect(error == expected)
      #expect(!"\(error)".contains(key))
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func aStreamForwardsDeltasAndReturnsTheCompletedResponse() async throws {
    let completed = metaReply.replacingOccurrences(of: "\n", with: "")
    let sse = """
      event: response.output_text.delta
      data: {"type":"response.output_text.delta","delta":"po"}
      data: {"type":"response.output_text.delta","delta":"ng"}
      data: {"type":"response.completed","response":\(completed)}
      data: [DONE]
      """
    let wire = Wire()
    wire.reply = { _ in (200, sse) }
    let deltas = Deltas()
    var request = ask()
    request.onDelta = { deltas.add($0) }
    let response = try await client(wire).call(request, source: "t")
    #expect(wire.body()["stream"]?.bool == true)
    #expect(wire.requests.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(deltas.all == ["po", "ng"])
    #expect(response.text == "pong")
  }

  @Test func aFailedStreamEnvelopeIsBilledOnceAndNeverCompletes() async throws {
    let path = ledgerPath()
    let failed = metaReply.replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: #""usage""#, with: #""status":"failed","usage""#)
    let wire = Wire()
    wire.reply = { _ in (200, #"data: {"type":"response.failed","response":\#(failed)}"#) }
    var request = ask()
    request.onDelta = { _ in }
    let response = try await client(wire, ledger: path).call(request, source: "t")
    #expect(response.incompleteReason == "failed")
    #expect(wire.requests.count == 1)
    let spent = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(spent?["entries"]?.array?.count == 1)
  }

  @Test func aFailedStreamEnvelopeWithoutStatusIsStillFailed() async throws {
    let bare = metaReply.replacingOccurrences(of: "\n", with: "")
    let wire = Wire()
    wire.reply = { _ in (200, #"data: {"type":"response.failed","response":\#(bare)}"#) }
    var request = ask()
    request.onDelta = { _ in }
    #expect(try await client(wire).call(request, source: "t").incompleteReason == "failed")
  }

  @Test func aFailureWithoutAUsableEnvelopeStaysAnErrorWithNoSpend() async {
    let noUsage = #"{"id":"resp_1","model":"muse-spark-1.3","output":[],"status":"failed"}"#
    for line in [
      #"data: {"type":"response.failed"}"#, #"data: {"type":"error","message":"boom"}"#,
      #"data: {"type":"response.failed","response":\#(noUsage)}"#,
    ] {
      let path = ledgerPath()
      let wire = Wire()
      wire.reply = { _ in (200, line) }
      var request = ask()
      request.onDelta = { _ in }
      await #expect(throws: ModelError.self) {
        try await client(wire, ledger: path).call(request, source: "t")
      }
      #expect(!FileManager.default.fileExists(atPath: path))
    }
  }

  @Test func aStreamThatEndsWithoutCompletionIsMalformed() async {
    let wire = Wire()
    wire.reply = { _ in (200, #"data: {"type":"response.output_text.delta","delta":"x"}"#) }
    var request = ask()
    request.onDelta = { _ in }
    await #expect(throws: ModelError.self) { try await client(wire).call(request, source: "t") }
  }
}

struct ModelAvailabilityTests {
  @Test func metaFollowsItsUrlOverrideAndTheProbeGoesToTheSelectedBase() async throws {
    let wire = Wire()
    wire.reply = { _ in (200, metaReply) }
    let env = ["MODEL_API_KEY": key, "BARESTATE_META_URL": "http://127.0.0.1:47881/v1"]
    _ = try await client(wire, environment: env).call(ask(), source: "t")
    #expect(wire.requests.first?.url?.absoluteString == "http://127.0.0.1:47881/v1/responses")
    #expect(client(wire, environment: env).probeURL?.absoluteString == "http://127.0.0.1:47881/v1")
    #expect(client(wire).probeURL?.absoluteString == "https://api.meta.ai/v1")
    let baseten = ["BASETEN_API_KEY": "bt", "BARESTATE_BASETEN_URL": "http://127.0.0.1:47882/v1"]
    #expect(
      client(wire, environment: baseten).probeURL?.absoluteString == "http://127.0.0.1:47882/v1")
  }

  @Test func theKeyIsPresentFromTheEnvironmentTheFileOrTheKeychainAndNothingIsSent() {
    let wire = Wire()
    #expect(client(wire).hasKey)
    #expect(client(wire, environment: [:], envFile: "MODEL_API_KEY=k\n").hasKey)
    #expect(client(wire, environment: [:], keychain: { "k" }).hasKey)
    #expect(client(wire, environment: ["BASETEN_API_KEY": "bt"]).hasKey)
    #expect(!client(wire, environment: [:]).hasKey)
    #expect(!client(wire, environment: ["MODEL_API_KEY": " "]).hasKey)
    #expect(wire.requests.isEmpty)
  }

  @Test func everyFailedCallIsReportedOnceAndASuccessIsNot() async throws {
    let seen = Failures()
    let wire = Wire()
    wire.reply = { _ in throw URLError(.cannotConnectToHost) }
    let failing = ModelClient(
      environment: ["MODEL_API_KEY": key], envFile: nil, ledger: SpendLedger(path: ledgerPath()),
      transport: wire.transport, onFailure: { seen.add($0) })
    await #expect(throws: ModelError.unreachable) { try await failing.call(ask(), source: "t") }
    #expect(seen.all == [.unreachable])
    wire.reply = { _ in (200, metaReply) }
    _ = try await failing.call(ask(), source: "t")
    #expect(seen.all == [.unreachable])
  }

  @Test func aCancelledCallIsNotAnOutage() async {
    let wire = Wire()
    wire.reply = { _ in throw URLError(.cancelled) }
    do {
      _ = try await client(wire).call(ask(), source: "t")
      Issue.record("expected a failure")
    } catch let error as ModelError {
      #expect(!error.isOutage)
    } catch {
      Issue.record("\(error)")
    }
  }
}

private final class Failures: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [ModelError] = []
  func add(_ error: ModelError) { lock.withLock { items.append(error) } }
  var all: [ModelError] { lock.withLock { items } }
}

private final class Deltas: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ text: String) { lock.withLock { items.append(text) } }
  var all: [String] { lock.withLock { items } }
}
