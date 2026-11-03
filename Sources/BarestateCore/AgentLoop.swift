import Foundation

/// The run's conversation with `muse-spark-1.3` (architecture §5.10): the model asks for a tool,
/// the tool's words go back on the same response chain, until it replies without asking. Beside
/// that chain the loop keeps the run's `Transcript`, to resend a turn when the provider has lost the
/// chain; what a tool does, and what a run is worth, belong to the caller.
public enum AgentLoop {
  public enum End: Sendable, Equatable {
    /// The model stopped asking for tools. `text` is its closing reply (its `refusal` part when it
    /// declined), nil when it said nothing; `refused` is true only for a structured refusal.
    case ended(text: String?, refused: Bool)
    /// `live` said the run is over (Stop, takeover): nothing more was sent or run.
    case stopped
    case failed(String)
  }

  /// The run's reason for a cut-off or unusable turn; the provider's own word stays off the run.
  public static let incompleteTurn = "model response incomplete"

  /// A run that has not stopped by now is going in circles.
  public static let maxTurns = 40

  public static let instructions = """
    You are Muse, working in the Photon browser on the user's behalf. Use the tools to look at \
    pages and to act on them.
    - Call `observe` before you act. `act` needs the `observationId` of the latest observe of that \
    page, and the `ref` of an element from it (or, if the element is not listed, `instruction`: a \
    few words naming it).
    - After every `act`, `observe` again and read the act result's `state` and `reason` before you \
    choose the next step. Only `confirmed` means the page changed as intended. `failed`, \
    `cancelled` and `outcome-unknown` mean it did not, or may not have, and you must not repeat \
    the same write without looking at the page first.
    - A sensitive action waits for a person to allow it; `act` returns when they have decided.
    - You control only the page you were given, or one you opened with `open_tab`. Use \
    `request_control` before acting on another page.
    - Never type or reveal passwords or payment details.
    - When the task is done, reply in one or two plain sentences and call no tool. If you cannot \
    finish it, say why.
    """

  private static func function(
    _ name: String, _ about: String, _ fields: [String: JSON] = [:], required: [String] = []
  ) -> JSON {
    [
      "type": "function", "name": .string(name), "description": .string(about),
      "parameters": [
        "type": "object", "properties": .object(fields),
        "required": .array(required.map { .string($0) }),
      ],
    ]
  }

  private static let text: JSON = ["type": "string"]
  private static let tabId: JSON = ["type": "string", "description": "A tab id from `tabs`."]

  /// The MCP tool set, in the shapes of the socket methods they call.
  public static let tools: [JSON] = [
    function("tabs", "List the open tabs: id, url, title."),
    function(
      "observe", "The page's visible elements with refs, and an observationId for `act`.",
      ["tabId": tabId]),
    function(
      "extract", "The page's text, or one element's, as plain text or markdown.",
      [
        "tabId": tabId, "format": ["type": "string", "enum": ["text", "markdown"]],
        "ref": ["type": "integer"],
      ]),
    function(
      "action_status", "The current state of an earlier act.",
      ["actionId": ["type": "integer"]], required: ["actionId"]),
    function(
      "open_tab", "Open a page in a new tab that you control.", ["url": text],
      required: ["url"]),
    function(
      "request_control", "Ask the person for control of a tab you do not control.",
      ["tabId": tabId], required: ["tabId"]),
    function("handoff", "Give a tab back to the person.", ["tabId": tabId], required: ["tabId"]),
    function(
      "act",
      "Click, type, select, press a key, scroll or navigate, aimed at a ref from an observation.",
      [
        "observationId": text,
        "kind": [
          "type": "string", "enum": ["click", "type", "select", "press", "scroll", "navigate"],
        ],
        "ref": ["type": "integer"], "instruction": text,
        "text": ["type": "string", "description": "What to type."],
        "value": ["type": "string", "description": "The option to select."],
        "key": text, "direction": ["type": "string", "enum": ["up", "down"]],
        "amount": ["type": "number"], "url": text,
      ], required: ["observationId", "kind"]),
  ]

  /// Runs until the model stops asking for tools, `live` goes false, the cap is reached or the
  /// turn limit is hit. `withinCap` is asked before every model call and every tool; `tool`
  /// returns the words that go back to the model. A turn the provider rejects for naming a
  /// response it does not hold is sent once more with the whole transcript and no chain, and
  /// `replayed` hears its turn number.
  @MainActor
  public static func run(
    prompt: String, live: () -> Bool, withinCap: () -> Bool, replayed: (Int) -> Void = { _ in },
    model: (ModelRequest) async throws -> ModelResponse,
    tool: (FunctionCall) async -> String
  ) async -> End {
    var transcript = Transcript(prompt: prompt)
    var input = transcript.items
    var previous: String?
    for turn in 1...maxTurns {
      guard live() else { return .stopped }
      guard withinCap() else { return .failed("run-cap") }
      var request = ModelRequest(
        instructions: instructions, input: input, tools: tools, previousResponseId: previous,
        maxOutputTokens: 1500)
      let response: ModelResponse
      do {
        do {
          response = try await model(request)
        } catch let error as ModelError
          where error.isMissingReference && previous != nil && live() && withinCap()
        {
          replayed(turn)
          request.input = transcript.items
          request.previousResponseId = nil
          response = try await model(request)
        }
      } catch {
        guard live() else { return .stopped }
        return .failed("\(error)")
      }
      guard live() else { return .stopped }
      guard response.incompleteReason == nil else { return .failed(incompleteTurn) }
      let calls = response.functionCalls
      if calls.isEmpty {
        let refusal = response.refusal
        let said = refusal.flatMap { $0.isEmpty ? nil : $0 } ?? response.text
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ended(text: text.isEmpty ? nil : text, refused: refusal != nil)
      }
      transcript.add(output: response.output)
      input = []
      for call in calls {
        guard live() else { return .stopped }
        guard withinCap() else { return .failed("run-cap") }
        let output = await tool(call)
        input.append([
          "type": "function_call_output", "call_id": .string(call.callId),
          "output": .string(output),
        ])
      }
      guard live() else { return .stopped }
      transcript.add(results: input)
      previous = response.id
    }
    return .failed("turn-limit")
  }
}
