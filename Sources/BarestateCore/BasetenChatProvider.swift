import Foundation

/// OpenAI-style `POST /chat/completions` for Baseten. Function tools and images only: Chat has
/// no computer tool, and no server-side state, so callers replay the whole conversation.
struct BasetenChatProvider: ModelProvider {
  let model: String
  let key: String
  let http: ModelHTTP
  let baseURL: URL

  func respond(_ request: ModelRequest) async throws -> ModelResponse {
    guard !request.computer else {
      throw ModelError.refused("the Baseten adapter has no computer tool")
    }
    var body: [String: JSON] = [
      "model": .string(model),
      "messages": .array(try Self.messages(request)),
      "max_tokens": .number(Double(request.maxOutputTokens)),
    ]
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map { tool in
          [
            "type": "function",
            "function": [
              "name": tool["name"] ?? .null, "description": tool["description"] ?? .null,
              "parameters": tool["parameters"] ?? .null,
            ],
          ]
        })
    }
    if let schema = request.schema {
      body["response_format"] = [
        "type": "json_schema",
        "json_schema": ["name": .string(schema.name), "strict": true, "schema": schema.schema],
      ]
    }
    let (data, requestId) = try await http.post(
      baseURL.appendingPathComponent("chat/completions"), key: key, body: .object(body))
    var parsed = try Self.parse(try ModelHTTP.json(data))
    parsed.requestId = requestId
    return parsed
  }

  private static func messages(_ request: ModelRequest) throws -> [JSON] {
    var messages: [JSON] = []
    if let instructions = request.instructions {
      messages.append(["role": "system", "content": .string(instructions)])
    }
    for item in request.input {
      if let role = item["role"]?.string, let content = item["content"] {
        messages.append(["role": .string(role), "content": chatContent(content)])
      } else if item["type"]?.string == "function_call", let id = item["call_id"] {
        let call: JSON = [
          "id": id, "type": "function",
          "function": ["name": item["name"] ?? .null, "arguments": item["arguments"] ?? "{}"],
        ]
        if case .object(var last)? = messages.last, last["tool_calls"] != nil {
          last["tool_calls"] = .array((last["tool_calls"]?.array ?? []) + [call])
          messages[messages.count - 1] = .object(last)
        } else {
          messages.append(["role": "assistant", "content": .null, "tool_calls": [call]])
        }
      } else if item["type"]?.string == "function_call_output" {
        messages.append([
          "role": "tool", "tool_call_id": item["call_id"] ?? .null,
          "content": item["output"] ?? "",
        ])
      } else {
        throw ModelError.malformed("input item the chat adapter cannot send")
      }
    }
    return messages
  }

  private static func chatContent(_ content: JSON) -> JSON {
    guard let parts = content.array else { return content }
    return .array(
      parts.map { part in
        switch part["type"]?.string {
        case "input_image": ["type": "image_url", "image_url": ["url": part["image_url"] ?? .null]]
        default: ["type": "text", "text": part["text"] ?? .null]
        }
      })
  }

  private static func parse(_ json: JSON) throws -> ModelResponse {
    guard let id = json["id"]?.string, let model = json["model"]?.string,
      let message = json["choices"]?[0]?["message"],
      let input = json["usage"]?["prompt_tokens"]?.int,
      let generated = json["usage"]?["completion_tokens"]?.int
    else { throw ModelError.malformed("response has no choices or usage") }
    var output: [JSON] = []
    var broken = false
    if let text = message["content"]?.string, !text.isEmpty {
      output.append([
        "type": "message", "role": "assistant",
        "content": [["type": "output_text", "text": .string(text)]],
      ])
    }
    for call in message["tool_calls"]?.array ?? [] {
      guard let callId = call["id"]?.string, let name = call["function"]?["name"]?.string,
        let arguments = call["function"]?["arguments"]?.string
      else {
        broken = true
        continue
      }
      output.append([
        "type": "function_call", "call_id": .string(callId), "name": .string(name),
        "arguments": .string(arguments),
      ])
    }
    let cached = json["usage"]?["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0
    var parsed = ModelResponse(
      id: id, model: model, output: output,
      usage: try ModelUsage.parsed(input: input, output: generated, cached: cached),
      endpoint: "/chat/completions")
    if json["choices"]?[0]?["finish_reason"]?.string == "length" {
      parsed.incompleteReason = "length"
    } else if broken {
      parsed.incompleteReason = "malformed function call"
    }
    return parsed
  }
}
