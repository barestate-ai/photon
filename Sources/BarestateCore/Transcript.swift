/// The run's own copy of the conversation, so a turn can be resent without the provider's chain
/// (architecture §5.10): the prompt, then each turn's replayable output items, then the results
/// of that turn's calls.
public struct Transcript: Sendable, Equatable {
  public private(set) var items: [JSON]

  public init(prompt: String) {
    items = [["role": "user", "content": .string(prompt)]]
  }

  /// Reasoning items stay behind: their ids point into the provider's chain, which a replay
  /// does not use. A `message` keeps its `phase`.
  public mutating func add(output: [JSON]) {
    items += output.filter { ["message", "function_call"].contains($0["type"]?.string ?? "") }
  }

  public mutating func add(results: [JSON]) { items += results }
}
