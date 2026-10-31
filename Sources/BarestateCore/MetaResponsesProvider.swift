import Foundation

/// Meta Model API `POST /responses` (library/models.md): function tools, image input,
/// JSON-schema output, the computer tool and SSE.
struct MetaResponsesProvider: ModelProvider {
  let model: String
  let key: String
  let http: ModelHTTP
  let baseURL: URL

  func respond(_ request: ModelRequest) async throws -> ModelResponse {
    var body: [String: JSON] = [
      "model": .string(model),
      "input": .array(request.input),
      "max_output_tokens": .number(Double(request.maxOutputTokens)),
      "reasoning": ["effort": .string(request.effort)],
    ]
    if let instructions = request.instructions { body["instructions"] = .string(instructions) }
    let tools = request.tools + (request.computer ? [["type": "computer"]] : [])
    if !tools.isEmpty { body["tools"] = .array(tools) }
    if let id = request.previousResponseId { body["previous_response_id"] = .string(id) }
    if let schema = request.schema {
      body["text"] = [
        "format": [
          "type": "json_schema", "name": .string(schema.name), "strict": true,
          "schema": schema.schema,
        ]
      ]
    }
    let streaming = request.onDelta != nil
    if streaming { body["stream"] = true }

    let (data, requestId) = try await http.post(
      baseURL.appendingPathComponent("responses"), key: key, body: .object(body),
      onLine: request.onDelta.map(Self.deltaForwarder))
    let (response, failed) = streaming ? try Self.terminal(data) : (try ModelHTTP.json(data), false)
    var parsed = try Self.parse(
      response, endpoint: streaming ? "/responses (stream)" : "/responses", failed: failed)
    guard parsed.model == model else {
      throw ModelError.malformed("answered by \(parsed.model), not \(model)")
    }
    parsed.requestId = requestId
    return parsed
  }

  private static func deltaForwarder(_ forward: @escaping @Sendable (String) -> Void)
    -> @Sendable (String) -> Void
  {
    { line in
      if let event = Self.event(line), event["type"]?.string == "response.output_text.delta",
        let text = event["delta"]?.string
      {
        forward(text)
      }
    }
  }

  private static func event(_ line: String) -> JSON? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    return payload == "[DONE]" ? nil : JSON.parse(Data(payload.utf8))
  }

  /// A failed response still carries the usage the provider billed, so its envelope is read like
  /// the others; `failed` keeps it from reading as a completed turn.
  private static func terminal(_ stream: Data) throws -> (JSON, failed: Bool) {
    for line in String(decoding: stream, as: UTF8.self).split(whereSeparator: \.isNewline) {
      guard let event = event(String(line)) else { continue }
      let type = event["type"]?.string
      switch type {
      case "response.completed", "response.incomplete", "response.failed":
        if let response = event["response"] { return (response, type == "response.failed") }
        if type == "response.failed" { throw ModelError.malformed("the stream reported a failure") }
      case "error": throw ModelError.malformed("the stream reported a failure")
      default: continue
      }
    }
    throw ModelError.malformed("the stream ended without response.completed")
  }

  private static func parse(_ json: JSON, endpoint: String, failed: Bool) throws -> ModelResponse {
    guard let id = json["id"]?.string, let model = json["model"]?.string,
      let output = json["output"]?.array, let input = json["usage"]?["input_tokens"]?.int,
      let generated = json["usage"]?["output_tokens"]?.int
    else { throw ModelError.malformed("response has no output or usage") }
    let cached = json["usage"]?["input_tokens_details"]?["cached_tokens"]?.int ?? 0
    var parsed = ModelResponse(
      id: id, model: model, output: output,
      usage: try ModelUsage.parsed(input: input, output: generated, cached: cached),
      endpoint: endpoint)
    let status = failed ? "failed" : json["status"]?.string ?? "completed"
    if status != "completed" {
      parsed.incompleteReason = json["incomplete_details"]?["reason"]?.string ?? status
    } else if output.filter({ $0["type"]?.string == "function_call" }).count
      != parsed.functionCalls.count
    {
      parsed.incompleteReason = "malformed function call"
    }
    return parsed
  }
}
