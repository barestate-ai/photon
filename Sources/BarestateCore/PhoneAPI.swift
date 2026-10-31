import Foundation

/// The phone's `/api/*` routes in terms of the app's socket methods, and the app's events in terms
/// of server-sent events. The gateway names the session itself, as it does for MCP: a phone never
/// chooses whose run it starts or stops.
public enum PhoneAPI {
  public enum Prepared: Equatable, Sendable {
    /// A request line for the socket.
    case call(line: Data)
    case refuse(status: Int, error: String)
  }

  public static let maxPrompt = 4000
  /// Every event the gateway relays, and which of them are screencast frames.
  private static let events: Set<String> = [
    "screencast.frame", "run.update", "tab.update", "approval.update",
  ]

  public static func session(hash: String) -> String { "phone-" + hash.prefix(8) }

  public static func prepare(route: String, body: Data, session: String) -> Prepared {
    let params: [String: JSON]
    switch route {
    case "task", "stop", "takeover", "approve":
      guard let parsed = JSON.parse(body)?.object else { return bad }
      params = parsed
    case "disconnect": params = [:]
    default: return .refuse(status: 404, error: "not-found")
    }
    func text(_ key: String) -> String? {
      params[key]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { $0.isEmpty ? nil : $0 }
    }
    switch route {
    case "task":
      guard let prompt = text("prompt"), prompt.count <= maxPrompt else { return bad }
      return call(
        "run.start",
        ["prompt": .string(prompt), "origin": "phone", "remoteSession": .string(session)])
    case "stop", "takeover":
      guard let runId = text("runId") else { return bad }
      return call(
        route == "stop" ? "run.stop" : "run.takeover",
        ["runId": .string(runId), "remoteSession": .string(session)])
    case "approve":
      guard let id = text("approvalId"), let allow = params["allow"]?.bool else { return bad }
      return call(
        "approval.decide",
        ["approvalId": .string(id), "allow": .bool(allow), "remoteSession": .string(session)])
    default:
      return call("remote.disconnect", ["session": .string(session)])
    }
  }

  /// The HTTP status and body for the app's reply line.
  public static func respond(_ reply: Data) -> (status: Int, body: Data) {
    guard let message = JSON.parse(reply)?.object else { return (502, error("bad-gateway")) }
    if let failure = message["error"] {
      let text = failure["message"]?.string ?? "failed"
      switch failure["code"]?.int {
      case -32602: return (400, error(text))
      case -32000: return text == "no-session" ? (409, error(text)) : (404, error(text))
      default: return (502, error("bad-gateway"))
      }
    }
    return (200, Data((message["result"] ?? .object([:])).serialized().utf8))
  }

  /// One app notification as an event, or nil for a reply or a method the phone does not get.
  public static func sse(from line: Data) -> (frame: Bool, bytes: Data)? {
    guard let message = JSON.parse(line)?.object, message["id"] == nil,
      let method = message["method"]?.string, events.contains(method)
    else { return nil }
    let data = (message["params"] ?? .object([:])).serialized()
    return (method == "screencast.frame", Data("event: \(method)\ndata: \(data)\n\n".utf8))
  }

  private static let bad = Prepared.refuse(status: 400, error: "bad-request")

  private static func call(_ method: String, _ params: [String: JSON]) -> Prepared {
    let message: JSON = [
      "jsonrpc": "2.0", "id": 1, "method": .string(method), "params": .object(params),
    ]
    return .call(line: Data((message.serialized() + "\n").utf8))
  }

  private static func error(_ text: String) -> Data {
    Data(JSON.object(["error": .string(text)]).serialized().utf8)
  }
}
