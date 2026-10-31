import Foundation

/// MCP over JSON-RPC for both protocol eras, with no per-connection state (architecture §5.12).
/// A request whose `_meta` names a protocol version is modern (2026-07-28); anything without one
/// is answered as legacy. `backend` runs a tool by the name of its socket method and returns what
/// that method returns; a failure becomes a tool error, never a protocol error.
@MainActor
public struct MCPServer {
  public typealias Backend = @MainActor (String, JSON) async throws -> JSON

  public nonisolated static let methods = [
    "initialize", "notifications/initialized", "ping", "server/discover", "tools/list",
    "tools/call",
  ]
  /// Set by the transport (stdio, gateway) in `_meta`: whose requests these are.
  public nonisolated static let sessionKey = "barestate/session"

  static let versionKey = "io.modelcontextprotocol/protocolVersion"
  static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
  static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
  static let modernVersions = ["2026-07-28", "2025-11-25"]
  static let legacyVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
  static let instructions =
    "Photon browser tools. tabs, observe, extract and action_status only read. open_tab gives "
    + "you control of the tab it opens; request_control asks the person for another tab; act "
    + "needs a clientActionId and a sensitive action waits for the person to allow it (follow it "
    + "with action_status); handoff gives a tab back."

  private let version: String
  private let backend: Backend

  public init(version: String, backend: @escaping Backend) {
    self.version = version
    self.backend = backend
  }

  private var serverInfo: JSON { ["name": "barestate-mcp", "version": .string(version)] }

  public func handle(_ method: String, _ params: JSON) async throws -> JSON {
    switch method {
    case "initialize":
      let asked = params["protocolVersion"]?.string ?? ""
      return [
        "protocolVersion": .string(Self.legacyVersions.contains(asked) ? asked : "2025-11-25"),
        "capabilities": ["tools": [:]], "serverInfo": serverInfo,
        "instructions": .string(Self.instructions),
      ]
    case "ping": return [:]
    case "notifications/initialized": return .null
    case "server/discover":
      _ = try modern(params)
      return complete([
        "supportedVersions": .array(Self.modernVersions.map { .string($0) }),
        "capabilities": ["tools": [:]], "instructions": .string(Self.instructions),
        "ttlMs": 60_000, "cacheScope": "public",
      ])
    case "tools/list":
      let isModern = try modern(params)
      let fields: [String: JSON] = ["tools": .array(Self.tools)]
      return isModern
        ? complete(fields.merging(["ttlMs": 60_000, "cacheScope": "public"]) { $1 })
        : .object(fields)
    case "tools/call":
      let isModern = try modern(params)
      let result = try await call(params)
      return isModern ? complete(result.object ?? [:]) : result
    default: throw RPCError.methodNotFound
    }
  }

  /// Whether the request is modern. Both `_meta` keys are required once either is present.
  private func modern(_ params: JSON) throws -> Bool {
    let meta = params["_meta"]
    let (version, capabilities) = (meta?[Self.versionKey], meta?[Self.capabilitiesKey])
    if version == nil && capabilities == nil { return false }
    guard let asked = version?.string, capabilities?.object != nil else {
      throw RPCError.invalidParams(
        "_meta needs \(Self.versionKey) (string) and \(Self.capabilitiesKey) (object)")
    }
    guard Self.modernVersions.contains(asked) else {
      throw RPCError(
        code: -32022, message: "Unsupported protocol version",
        data: [
          "supported": .array(Self.modernVersions.map { .string($0) }), "requested": .string(asked),
        ])
    }
    return true
  }

  private func complete(_ fields: [String: JSON]) -> JSON {
    var result = fields
    result["resultType"] = "complete"
    result["_meta"] = [Self.serverInfoKey: serverInfo]
    return .object(result)
  }

  private func call(_ params: JSON) async throws -> JSON {
    guard let name = params["name"]?.string else {
      throw RPCError.invalidParams("name (string) required")
    }
    guard Self.tools.contains(where: { $0["name"] == .string(name) }) else {
      return Self.failure("unknown tool \(name)")
    }
    var arguments = [String: JSON]()
    if let given = params["arguments"], given != .null {
      guard let object = given.object else {
        throw RPCError.invalidParams("arguments must be an object")
      }
      arguments = object
    }
    // The transport's session is the only one a caller can act as, and a journal row is never
    // read by its number from outside the session that wrote it.
    arguments["sessionId"] = .string(params["_meta"]?[Self.sessionKey]?.string ?? "mcp")
    if name == "action_status" { arguments["actionId"] = nil }
    do {
      var result = try await backend(name, .object(arguments))
      result = .object((result.object ?? [:]).filter { $0.key != "approvalTokenHash" })
      var reply: [String: JSON] = [
        "content": [["type": "text", "text": .string(result.serialized())]],
        "structuredContent": result,
      ]
      // An act that did not happen comes back as a row; to the caller it is still an error.
      if name == "act", ["failed", "cancelled"].contains(result["state"]?.string) {
        reply["isError"] = true
      }
      return .object(reply)
    } catch {
      return Self.failure((error as? RPCError)?.message ?? "\(error)")
    }
  }

  private static func failure(_ reason: String) -> JSON {
    ["content": [["type": "text", "text": .string(reason)]], "isError": true]
  }

  // MARK: Tools

  /// The agent loop's tools, with what an outside client needs on top: `act` is told apart by the
  /// caller's `clientActionId`, and `action_status` reads by it.
  public static let tools: [JSON] = AgentLoop.tools.map { tool in
    let name = tool["name"]?.string ?? ""
    var schema = tool["parameters"]?.object ?? [:]
    var properties = schema["properties"]?.object ?? [:]
    var required = schema["required"]?.array ?? []
    var about = tool["description"]?.string ?? ""
    switch name {
    case "act":
      properties["clientActionId"] = [
        "type": "string",
        "description": "Your id for this action. Repeating it returns the same action.",
      ]
      required.append("clientActionId")
    case "action_status":
      properties = ["clientActionId": ["type": "string"]]
      required = ["clientActionId"]
    case "open_tab":
      properties["tabId"] = [
        "type": "string", "description": "A tab you control, to navigate instead of opening one.",
      ]
      about = "Open a page in a new tab that you control, or navigate a tab you control."
    default: break
    }
    schema["properties"] = .object(properties)
    schema["required"] = .array(required)
    schema["additionalProperties"] = false
    return [
      "name": .string(name), "description": .string(about), "inputSchema": .object(schema),
      "annotations": annotations(name),
    ]
  }

  private static func annotations(_ name: String) -> JSON {
    func hints(destructive: Bool, idempotent: Bool, openWorld: Bool) -> JSON {
      [
        "readOnlyHint": false, "destructiveHint": .bool(destructive),
        "idempotentHint": .bool(idempotent), "openWorldHint": .bool(openWorld),
      ]
    }
    switch name {
    case "open_tab": return hints(destructive: false, idempotent: false, openWorld: true)
    case "request_control", "handoff":
      return hints(destructive: false, idempotent: true, openWorld: false)
    case "act": return hints(destructive: true, idempotent: true, openWorld: true)
    default: return ["readOnlyHint": true]
    }
  }
}
