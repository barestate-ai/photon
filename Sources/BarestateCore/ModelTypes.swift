import Foundation

public struct ModelUsage: Sendable, Equatable {
  public let input: Int
  public let output: Int
  public let cached: Int

  public init(input: Int, output: Int, cached: Int) {
    self.input = input
    self.output = output
    self.cached = cached
  }

  /// Token counts from the wire: a negative count or more cached than input would lower the
  /// ledger total.
  static func parsed(input: Int, output: Int, cached: Int) throws -> ModelUsage {
    guard input >= 0, output >= 0, (0...input).contains(cached) else {
      throw ModelError.malformed("impossible token counts")
    }
    return ModelUsage(input: input, output: output, cached: cached)
  }
}

public struct FunctionCall: Sendable, Equatable {
  public let callId: String
  public let name: String
  public let arguments: String

  public init(callId: String, name: String, arguments: String) {
    self.callId = callId
    self.name = name
    self.arguments = arguments
  }
}

/// What the agent loop, the verifier and the computer tool ask of a model. `input` and `tools`
/// use the Responses shapes (flat function tools); the Baseten adapter translates them.
public struct ModelRequest: Sendable {
  public var instructions: String?
  public var input: [JSON]
  public var tools: [JSON]
  public var computer: Bool
  public var schema: (name: String, schema: JSON)?
  public var previousResponseId: String?
  public var maxOutputTokens: Int
  public var effort: String
  /// Setting it turns on SSE streaming (Meta only); it sees each text delta as it arrives.
  public var onDelta: (@Sendable (String) -> Void)?

  public init(
    instructions: String? = nil, input: [JSON], tools: [JSON] = [], computer: Bool = false,
    schema: (name: String, schema: JSON)? = nil, previousResponseId: String? = nil,
    maxOutputTokens: Int = 400, effort: String = "low"
  ) {
    self.instructions = instructions
    self.input = input
    self.tools = tools
    self.computer = computer
    self.schema = schema
    self.previousResponseId = previousResponseId
    self.maxOutputTokens = maxOutputTokens
    self.effort = effort
  }
}

/// Both providers answer in the Responses item shapes, so callers never branch on the provider.
public struct ModelResponse: Sendable {
  public let id: String
  public let model: String
  public let output: [JSON]
  public let usage: ModelUsage
  public let endpoint: String
  public var requestId: String?
  public var usd = 0.0
  /// Why this turn is not a finished answer: the provider cut it off or failed it, or it carries
  /// a function call that cannot be run. Such a turn is never the model ending.
  public var incompleteReason: String?

  private var contentParts: [JSON] {
    output.filter { $0["type"]?.string == "message" }.flatMap { $0["content"]?.array ?? [] }
  }

  public var text: String {
    contentParts.compactMap { $0["type"]?.string == "output_text" ? $0["text"]?.string : nil }
      .joined()
  }

  /// The words of the response's `refusal` content parts: nil when the provider sent none, so
  /// the model declining is only ever read from the structured part, never from its wording.
  public var refusal: String? {
    let parts = contentParts.filter { $0["type"]?.string == "refusal" }
    return parts.isEmpty ? nil : parts.compactMap { $0["refusal"]?.string }.joined()
  }

  public var functionCalls: [FunctionCall] {
    output.compactMap { item in
      guard item["type"]?.string == "function_call", let callId = item["call_id"]?.string,
        let name = item["name"]?.string, let arguments = item["arguments"]?.string
      else { return nil }
      return FunctionCall(callId: callId, name: name, arguments: arguments)
    }
  }

  public var computerCall: JSON? { output.first { $0["type"]?.string == "computer_call" } }
}

public enum ModelError: Error, Equatable, CustomStringConvertible {
  case noKey
  case capReached(total: Double)
  case unreachable
  case timeout
  /// 5xx and 429: worth a retry later.
  case server(status: Int)
  /// Any other non-2xx: the request itself is wrong.
  case rejected(status: Int, message: String)
  case malformed(String)
  case refused(String)
  case ledger(String)

  public var description: String {
    switch self {
    case .noKey: "no model API key (MODEL_API_KEY, .env or Keychain meta-model-api)"
    case .capReached(let total): "spend cap reached: $\(total) of $\(SpendLedger.capUSD)"
    case .unreachable: "model unreachable"
    case .timeout: "model timed out"
    case .server(let status): "model server error \(status)"
    case .rejected(let status, let message): "model rejected the request (\(status)): \(message)"
    case .malformed(let what): "malformed model response: \(what)"
    case .refused(let why): "model call refused: \(why)"
    case .ledger(let why): "spend ledger: \(why)"
    }
  }

  /// A provider hiccup (5xx, 429): the same request may succeed a moment later. Nothing was billed.
  public var isTransient: Bool {
    if case .server = self { return true }
    return false
  }

  /// The request chained to a response id the provider does not hold. The id never comes back
  /// (the provider sometimes answers 200 for a response it never stores), so only a request that
  /// does not name it can succeed.
  public var isMissingReference: Bool {
    guard case .rejected(400, let message) = self else { return false }
    return message.contains("referenced response not found")
  }

  /// The provider could not be reached or is down, as opposed to a request it refused (429 is a
  /// rate limit, not an outage).
  public var isOutage: Bool {
    switch self {
    case .unreachable, .timeout: true
    case .server(let status): status >= 500
    default: false
    }
  }

  /// Stable word for logs and RPC replies.
  public var code: String {
    switch self {
    case .noKey: "no-key"
    case .capReached: "cap-reached"
    case .unreachable: "unreachable"
    case .timeout: "timeout"
    case .server: "server"
    case .rejected: "rejected"
    case .malformed: "malformed"
    case .refused: "refused"
    case .ledger: "ledger"
    }
  }
}

public protocol ModelProvider: Sendable {
  func respond(_ request: ModelRequest) async throws -> ModelResponse
}
