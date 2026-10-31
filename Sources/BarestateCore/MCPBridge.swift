import Foundation

/// Turns one HTTP body into what the gateway forwards to Photon's socket. Like the stdio proxy
/// it passes only the MCP methods, and it names the session itself: a remote client never
/// chooses whose requests these are, and never reaches the socket's approval methods.
public enum MCPBridge {
  public enum Outcome: Equatable, Sendable {
    /// A line for the socket; `id` is nil for a notification, which gets no reply.
    case forward(line: Data, id: JSON?)
    /// An answer made here, as a JSON-RPC error.
    case reply(Data)
    /// Nothing to do (a response, or a notification of a kind we do not carry).
    case accepted
  }

  public static func prepare(_ body: Data, session: String) -> Outcome {
    guard let parsed = try? JSONDecoder().decode(JSON.self, from: body) else {
      return error("Parse error", code: -32700, id: nil)
    }
    guard var message = parsed.object else {
      return error("Batches and bare values are not supported", code: -32600, id: nil)
    }
    let id = message["id"]
    if id == .null { return error("id must not be null", code: -32600, id: nil) }
    guard let method = message["method"]?.string else {
      return id == nil ? .accepted : error("method required", code: -32600, id: id)
    }
    guard MCPServer.methods.contains(method) else {
      return id == nil ? .accepted : error("Method not found", code: -32601, id: id)
    }
    // A notification gets no reply, so nothing it starts could be counted against a session limit.
    if id == nil && method != "notifications/initialized" { return .accepted }
    var params = message["params"]?.object ?? [:]
    var meta = params["_meta"]?.object ?? [:]
    meta[MCPServer.sessionKey] = .string(session)
    params["_meta"] = .object(meta)
    message["params"] = .object(params)
    return .forward(line: Data((JSON.object(message).serialized() + "\n").utf8), id: id)
  }

  public static func error(_ message: String, code: Int, id: JSON?) -> Outcome {
    .reply(Data(errorBody(message, code: code, id: id).utf8))
  }

  public static func errorBody(_ message: String, code: Int, id: JSON?) -> String {
    JSON.object([
      "jsonrpc": "2.0", "id": id ?? .null,
      "error": ["code": .number(Double(code)), "message": .string(message)],
    ]).serialized()
  }
}
