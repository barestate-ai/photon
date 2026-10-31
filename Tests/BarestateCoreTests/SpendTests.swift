import BarestateCore
import Foundation
import Testing

private final class Wire: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [(Int, String)]
  private(set) var bodies: [JSON] = []

  init(_ replies: [(Int, String)]) { queue = replies }

  var transport: ModelTransport {
    { [self] request, _ in
      let (status, body) = lock.withLock { () -> (Int, String) in
        bodies.append(JSON.parse(request.httpBody ?? Data()) ?? .null)
        return queue.removeFirst()
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (Data(body.utf8), response)
    }
  }
}

private let secret = "sk-test-secret-9876"
private func ledgerPath() -> String {
  NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
}

private func client(_ wire: Wire, ledger: String = ledgerPath()) -> ModelClient {
  ModelClient(
    environment: ["MODEL_API_KEY": secret], envFile: nil, ledger: SpendLedger(path: ledger),
    transport: wire.transport)
}

struct ProviderErrorTests {
  @Test func aProviderMessageThatEchoesTheKeyIsRedactedBeforeAnyoneSeesIt() async {
    let echoed = "Invalid key \(secret) for project (\(secret))"
    let wire = Wire([(401, #"{"error":{"message":"\#(echoed)"}}"#)])
    do {
      _ = try await client(wire).call(ModelRequest(input: ["hi"]), source: "t")
      Issue.record("expected a rejection")
    } catch let error as ModelError {
      guard case .rejected(let status, let message) = error else {
        Issue.record("wrong error \(error)")
        return
      }
      #expect(status == 401)
      #expect(!message.contains(secret) && !error.description.contains(secret))
      #expect(message.contains("[redacted]"))
    } catch {
      Issue.record("wrong error \(error)")
    }
  }

  @Test func aKeyCutByTheLengthLimitIsRedactedWholeNotLeftAsAPrefix() async {
    let echoed = String(repeating: "x", count: 190) + secret
    let wire = Wire([(400, #"{"error":{"message":"\#(echoed)"}}"#)])
    do {
      _ = try await client(wire).call(ModelRequest(input: ["hi"]), source: "t")
    } catch let error as ModelError {
      guard case .rejected(_, let message) = error else { return }
      #expect(!message.contains("sk-test"))
    } catch {}
  }
}

struct SpendByRunTests {
  @Test func callsLabelledWithASessionAreSummedPerSession() async throws {
    let path = ledgerPath()
    let reply = (
      200,
      #"{"id":"a","model":"muse-spark-1.3","output":[],"usage":{"input_tokens":1000000,"output_tokens":0}}"#
    )
    let wire = Wire([reply, reply, reply])
    let base = client(wire, ledger: path)
    _ = try await base.labelled("r1").call(ModelRequest(input: ["x"]), source: "loop")
    _ = try await base.labelled("r1").call(ModelRequest(input: ["x"]), source: "verify")
    _ = try await base.labelled("r10").call(ModelRequest(input: ["x"]), source: "loop")
    let ledger = SpendLedger(path: path)
    #expect(try ledger.spent(session: "r1") == 2.5)
    #expect(try ledger.spent(session: "r10") == 1.25)
    #expect(try ledger.spent(session: "r2") == 0)
    let entries = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))?["entries"]?.array
    #expect(entries?.compactMap { $0["source"]?.string } == ["r1:loop", "r1:verify", "r10:loop"])
  }
}

@Suite("Transient model errors")
struct TransientErrorTests {
  @Test func onlyAProviderHiccupIsWorthTheSameRequestAgain() {
    #expect(ModelError.server(status: 503).isTransient)
    #expect(ModelError.server(status: 429).isTransient)
    #expect(
      !ModelError.rejected(status: 400, message: "referenced response not found or expired")
        .isTransient)
    #expect(!ModelError.rejected(status: 400, message: "max_output_tokens too small").isTransient)
    #expect(!ModelError.noKey.isTransient)
    #expect(!ModelError.capReached(total: 40).isTransient)
  }

  @Test func onlyA400NamingAMissingResponseIsAMissingReference() {
    #expect(
      ModelError.rejected(status: 400, message: "referenced response not found or expired")
        .isMissingReference)
    #expect(
      !ModelError.rejected(status: 404, message: "referenced response not found").isMissingReference
    )
    #expect(!ModelError.rejected(status: 400, message: "bad schema").isMissingReference)
    #expect(!ModelError.server(status: 503).isMissingReference)
  }
}

@Suite("Run gate")
struct RunGateTests {
  @Test func aRefusedCallSendsNothingAndWritesNoSpend() async throws {
    let wire = Wire([])
    let path = ledgerPath()
    let gated = client(wire, ledger: path).labelled("r1", gate: { .refused("run-cap") })
    await #expect(throws: ModelError.refused("run-cap")) {
      _ = try await gated.call(ModelRequest(input: ["x"]), source: "ground")
    }
    #expect(wire.bodies.isEmpty)
    #expect(try SpendLedger(path: path).spent(session: "r1") == 0)
  }
}
