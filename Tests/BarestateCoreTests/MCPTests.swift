import BarestateCore
import Foundation
import Testing

@MainActor
struct MCPTests {
  private let modernMeta: JSON = [
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": [:],
  ]

  /// Records what reached the backend and answers like the socket methods do.
  private final class Calls {
    var seen: [(String, JSON)] = []
  }

  private func server(
    _ calls: Calls = Calls(), fail: RPCError? = nil, reply: [String: JSON]? = nil
  ) -> MCPServer {
    MCPServer(version: "9.9") { name, arguments in
      calls.seen.append((name, arguments))
      if let fail { throw fail }
      if let reply { return .object(reply) }
      return ["tool": .string(name), "state": "confirmed", "approvalTokenHash": "abc"]
    }
  }

  @Test func legacyInitializeEchoesAKnownVersionAndCarriesNoResultType() async throws {
    let result = try await server().handle("initialize", ["protocolVersion": "2025-06-18"])
    #expect(result["protocolVersion"] == "2025-06-18")
    #expect(result["capabilities"]?["tools"] != nil)
    #expect(result["serverInfo"]?["name"] == "barestate-mcp")
    #expect(result["resultType"] == nil)
    let unknown = try await server().handle("initialize", ["protocolVersion": "1900-01-01"])
    #expect(unknown["protocolVersion"] == "2025-11-25")
  }

  @Test func initializedGetsNothingAndPingGetsAnEmptyObject() async throws {
    #expect(try await server().handle("notifications/initialized", .null) == .null)
    #expect(try await server().handle("ping", .null) == [:])
  }

  @Test func discoverListsTheModernVersionWithTheFiveRequiredFields() async throws {
    let result = try await server().handle("server/discover", ["_meta": modernMeta])
    #expect(result["supportedVersions"]?.array?.contains("2026-07-28") == true)
    #expect(result["resultType"] == "complete")
    #expect(result["capabilities"]?["tools"] != nil)
    #expect(result["ttlMs"] != nil && result["cacheScope"] != nil)
    #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"] == "9.9")
  }

  @Test func aModernRequestMissingAMetaKeyIsInvalidParams() async {
    let onlyVersion: JSON = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]
    let onlyCapabilities: JSON = [
      "_meta": ["io.modelcontextprotocol/clientCapabilities": [:]]
    ]
    for params in [onlyVersion, onlyCapabilities] {
      do {
        _ = try await server().handle("tools/list", params)
        Issue.record("expected -32602")
      } catch let error as RPCError {
        #expect(error.code == -32602)
      } catch {
        Issue.record("\(error)")
      }
    }
  }

  @Test func anUnsupportedVersionIsNamedWithTheSupportedOnes() async {
    let params: JSON = [
      "_meta": [
        "io.modelcontextprotocol/protocolVersion": "1900-01-01",
        "io.modelcontextprotocol/clientCapabilities": [:],
      ]
    ]
    do {
      _ = try await server().handle("tools/list", params)
      Issue.record("expected -32022")
    } catch let error as RPCError {
      #expect(error.code == -32022)
      #expect(error.data?["supported"]?.array?.contains("2026-07-28") == true)
      #expect(error.data?["requested"] == "1900-01-01")
    } catch {
      Issue.record("\(error)")
    }
  }

  @Test func toolsListIsExactlyTheEightToolsWithHonestAnnotations() async throws {
    let legacy = try await server().handle("tools/list", .null)
    let tools = legacy["tools"]?.array ?? []
    #expect(
      tools.compactMap { $0["name"]?.string } == [
        "tabs", "observe", "extract", "action_status", "open_tab", "request_control", "handoff",
        "act",
      ])
    #expect(legacy["resultType"] == nil)
    for tool in tools {
      #expect(tool["inputSchema"]?["type"] == "object")
      #expect(tool["inputSchema"]?["additionalProperties"] == false)
      let readOnly = ["tabs", "observe", "extract", "action_status"].contains(tool["name"]?.string)
      #expect(tool["annotations"]?["readOnlyHint"] == .bool(readOnly))
    }
    let act = tools.last
    #expect(act?["annotations"]?["idempotentHint"] == true)
    #expect(act?["inputSchema"]?["required"]?.array?.contains("clientActionId") == true)
    let modern = try await server().handle("tools/list", ["_meta": modernMeta])
    #expect(modern["resultType"] == "complete")
    #expect(modern["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "barestate-mcp")
  }

  @Test func theTransportSessionReplacesWhateverTheCallerClaims() async throws {
    let calls = Calls()
    let result = try await server(calls).handle(
      "tools/call",
      [
        "name": "act", "arguments": ["sessionId": "someone-else", "clientActionId": "a1"],
        "_meta": ["barestate/session": "mcp-1"],
      ])
    #expect(calls.seen.first?.0 == "act")
    #expect(calls.seen.first?.1["sessionId"] == "mcp-1")
    #expect(calls.seen.first?.1["clientActionId"] == "a1")
    #expect(result["isError"] == nil)
    #expect(result["structuredContent"]?["state"] == "confirmed")
    #expect(result["content"]?[0]?["type"] == "text")
  }

  @Test func theApprovalTokenHashNeverLeavesAndActionStatusIgnoresARowNumber() async throws {
    let calls = Calls()
    let result = try await server(calls).handle(
      "tools/call",
      ["name": "action_status", "arguments": ["clientActionId": "a1", "actionId": 7]])
    #expect(result["structuredContent"]?["approvalTokenHash"] == nil)
    #expect(result["content"]?[0]?["text"]?.string?.contains("abc") == false)
    #expect(calls.seen.first?.1["actionId"] == nil)
  }

  @Test func aToolFailureAnUnknownToolAndAnActThatDidNotHappenAreErrorResults() async throws {
    let failing = server(fail: .invalidParams("clientActionId (string) required"))
    let result = try await failing.handle("tools/call", ["name": "act", "arguments": [:]])
    #expect(result["isError"] == true)
    #expect(result["content"]?[0]?["text"] == "clientActionId (string) required")
    let unknown = try await server().handle("tools/call", ["name": "format_disk"])
    #expect(unknown["isError"] == true)
    #expect(unknown["content"]?[0]?["text"] == "unknown tool format_disk")
    for state in ["failed", "cancelled"] {
      let ended = try await server(reply: ["state": .string(state), "reason": "stale: epoch"])
        .handle("tools/call", ["name": "act", "arguments": ["clientActionId": "a1"]])
      #expect(ended["isError"] == true)
      #expect(ended["structuredContent"]?["state"]?.string == state)
    }
    let confirmed = try await server(reply: ["state": "confirmed"])
      .handle("tools/call", ["name": "act", "arguments": ["clientActionId": "a1"]])
    #expect(confirmed["isError"] == nil)
  }

  @Test func modernToolResultsCarryTheResultTypeAndServerInfo() async throws {
    let result = try await server().handle(
      "tools/call", ["name": "tabs", "_meta": modernMeta])
    #expect(result["resultType"] == "complete")
    #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"] != nil)
    #expect(result["content"] != nil)
  }
}
