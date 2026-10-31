import BarestateCore
import Foundation
import Testing

struct MCPBridgeTests {
  private func prepare(_ text: String, session: String = "http-1") -> MCPBridge.Outcome {
    MCPBridge.prepare(Data(text.utf8), session: session)
  }

  private func object(_ data: Data) -> JSON? { JSON.parse(data) }

  @Test func aRequestIsForwardedAsTheTransportsSessionWhateverTheClientSays() throws {
    let body = """
      {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"tabs",\
      "_meta":{"barestate/session":"mcp-spoofed","other":1}}}
      """
    guard case .forward(let line, let id) = prepare(body) else {
      Issue.record("not forwarded")
      return
    }
    #expect(id == 7)
    #expect(line.last == 0x0A)
    let sent = try #require(object(line.dropLast()))
    #expect(sent["params"]?["_meta"]?["barestate/session"] == "http-1")
    #expect(sent["params"]?["_meta"]?["other"] == 1)
    #expect(sent["params"]?["name"] == "tabs")
  }

  @Test func aRequestWithoutParamsGetsOnlyTheSession() throws {
    guard case .forward(let line, _) = prepare(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
    else {
      Issue.record("not forwarded")
      return
    }
    let sent = try #require(object(line.dropLast()))
    #expect(sent["params"]?["_meta"] == ["barestate/session": "http-1"])
  }

  @Test func theSocketsOtherMethodsAreNeverForwarded() throws {
    for method in [
      "approval.decide", "control.decide", "run.start", "open_tab", "test.click", "tabs",
    ] {
      let outcome = prepare(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#)
      guard case .reply(let reply) = outcome else {
        Issue.record("\(method) was not refused")
        continue
      }
      #expect(object(reply)?["error"]?["code"] == -32601, "\(method)")
      #expect(object(reply)?["id"] == 1)
    }
  }

  @Test func notificationsAreAcceptedWithoutAReply() {
    guard
      case .forward(_, let id) = prepare(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    else {
      Issue.record("not forwarded")
      return
    }
    #expect(id == nil)
    #expect(prepare(#"{"jsonrpc":"2.0","method":"approval.decide"}"#) == .accepted)
    // Only a notification that starts nothing is forwarded: an act cannot run unseen by the limit.
    #expect(
      prepare(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"act"}}"#) == .accepted)
    #expect(prepare(#"{"jsonrpc":"2.0","result":{}}"#) == .accepted)
  }

  @Test func malformedBodiesGetJSONRPCErrors() {
    func code(_ text: String) -> JSON? {
      guard case .reply(let reply) = prepare(text) else { return nil }
      return object(reply)?["error"]?["code"]
    }
    #expect(code("not json") == -32700)
    #expect(code(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600)
    #expect(code("5") == -32600)
    #expect(code(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) == -32600)
    #expect(code(#"{"jsonrpc":"2.0","id":3}"#) == -32600)
    #expect(code("") == -32700)
  }
}
