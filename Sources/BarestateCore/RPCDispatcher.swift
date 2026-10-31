import Foundation

public struct RPCError: Error, Equatable, Sendable {
  public let code: Int
  public let message: String
  public let data: JSON?

  public init(code: Int, message: String, data: JSON? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  public static let parse = RPCError(code: -32700, message: "Parse error")
  public static let invalidRequest = RPCError(code: -32600, message: "Invalid Request")
  public static let methodNotFound = RPCError(code: -32601, message: "Method not found")
  public static let unexpected = RPCError(code: -32603, message: "Internal error")

  public static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: -32602, message: message)
  }
}

/// JSON-RPC 2.0 over single messages (no batches). Handlers run on the main actor, which owns
/// CEF, tabs and control state.
@MainActor
public final class RPCDispatcher {
  public typealias Handler = @MainActor (JSON) async throws -> JSON

  private let testHooks: Bool
  private var handlers: [String: Handler] = [:]

  public init(testHooks: Bool) {
    self.testHooks = testHooks
  }

  public func register(_ method: String, _ handler: @escaping Handler) {
    handlers[method] = handler
  }

  /// The handler a socket client would reach, for a caller inside the process (the run loop).
  public func call(_ method: String, _ params: JSON) async throws -> JSON {
    guard let handler = lookup(method) else { throw RPCError.methodNotFound }
    return try await handler(params)
  }

  /// Returns the encoded reply, or nil for a notification (a request without an id).
  public func handle(line: Data) async -> Data? {
    guard let message = try? JSONDecoder().decode(JSON.self, from: line) else {
      return reply(id: .null, error: .parse)
    }
    guard message["jsonrpc"] == .string("2.0"), case .string(let method)? = message["method"]
    else {
      return reply(id: message["id"] ?? .null, error: .invalidRequest)
    }
    let id = message["id"]
    let outcome: Result<JSON, RPCError>
    if let handler = lookup(method) {
      do {
        outcome = .success(try await handler(message["params"] ?? .null))
      } catch let error as RPCError {
        outcome = .failure(error)
      } catch {
        outcome = .failure(.unexpected)
      }
    } else {
      outcome = .failure(.methodNotFound)
    }
    guard let id else { return nil }
    switch outcome {
    case .success(let result):
      return encode(["jsonrpc": .string("2.0"), "id": id, "result": result])
    case .failure(let error): return reply(id: id, error: error)
    }
  }

  private func lookup(_ method: String) -> Handler? {
    if method.hasPrefix("test.") && !testHooks { return nil }
    return handlers[method]
  }

  private func reply(id: JSON, error: RPCError) -> Data? {
    var body: [String: JSON] = [
      "code": .number(Double(error.code)), "message": .string(error.message),
    ]
    body["data"] = error.data
    return encode(["jsonrpc": .string("2.0"), "id": id, "error": .object(body)])
  }

  private func encode(_ fields: [String: JSON]) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(JSON.object(fields))
  }
}
