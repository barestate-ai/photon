import BarestateCore
import Foundation
import Testing

private final class ScriptedTransport: CDPTransport, @unchecked Sendable {
  let events = AsyncStream<CDPEvent>.makeStream().stream
  private let lock = NSLock()
  private var calls: [(method: String, params: JSON)] = []

  var made: [(method: String, params: JSON)] { lock.withLock { calls } }

  func send(_ method: String, _ params: JSON) async throws -> JSON {
    lock.withLock { calls.append((method, params)) }
    switch method {
    case "Page.getFrameTree": return ["frameTree": ["frame": ["id": "F1", "loaderId": "L1"]]]
    case "Page.createIsolatedWorld": return ["executionContextId": 42]
    case "DOM.resolveNode":
      guard params["backendNodeId"] == 99 else {
        throw CDPError.remote(code: -32000, message: "No node")
      }
      return ["object": ["objectId": "obj-1"]]
    case "Runtime.releaseObject": return [:]
    case "Runtime.evaluate", "Runtime.callFunctionOn":
      return ["result": ["type": "string", "value": "extracted"]]
    default: throw CDPError.remote(code: -32601, message: method)
    }
  }
}

struct ExtractorTests {
  @Test func wholePageRunsInTheIsolatedContext() async throws {
    let transport = ScriptedTransport()
    let content = try await Extractor.extract(transport: transport, format: .markdown)
    #expect(content == "extracted")
    #expect(
      transport.made.map(\.method) == [
        "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate",
      ])
    let world = transport.made[1].params
    #expect(world["frameId"] == "F1")
    #expect(world["worldName"] == "barestate")
    let evaluate = transport.made[2].params
    #expect(evaluate["contextId"] == 42)
    #expect(evaluate["expression"]?.string?.hasSuffix(#".call(document.body, "markdown")"#) == true)
  }

  @Test func aRefResolvesInsideTheIsolatedContextAndRunsOnThatNode() async throws {
    let transport = ScriptedTransport()
    _ = try await Extractor.extract(transport: transport, format: .text, ref: 99)
    #expect(
      transport.made.map(\.method)
        == [
          "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode",
          "Runtime.callFunctionOn", "Runtime.releaseObject",
        ])
    #expect(transport.made[4].params["objectId"] == "obj-1")
    #expect(transport.made[2].params["executionContextId"] == 42)
    #expect(transport.made[3].params["objectId"] == "obj-1")
    #expect(transport.made[3].params["arguments"]?[0]?["value"] == "text")
  }

  @Test func anUnknownRefFailsWithoutRunningAnything() async {
    let transport = ScriptedTransport()
    await #expect(throws: CDPError.self) {
      try await Extractor.extract(transport: transport, format: .text, ref: 7)
    }
    #expect(!transport.made.contains { $0.method == "Runtime.callFunctionOn" })
  }

  @Test func theScriptDeclaresNoGlobals() {
    #expect(!Extractor.script.contains("window."))
    #expect(Extractor.script.hasPrefix("function (format)"))
  }
}
