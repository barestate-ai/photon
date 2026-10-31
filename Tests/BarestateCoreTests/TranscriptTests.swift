import BarestateCore
import Foundation
import Testing

/// `output` arrays copied from recorded replies of muse-spark-1.3 on a fixture page: a turn with
/// reasoning, a commentary `message` and a `function_call`, and a turn with reasoning and a call.
let recordedTurnOne = """
  [{"type":"reasoning","id":"rs_6ae58257326dcafc6b2146a9:rs_4ad5addb-ffe2-49e3-851f-d584b258903b",
  "summary":[],"status":"completed"},
  {"type":"message","id":"rs_7632385f-42f0-4351-bfc0-a7fd1773143c","role":"assistant",
  "content":[{"type":"output_text","text":"I'll observe your page and click Count once.",
  "annotations":[],"logprobs":[]}],"phase":"commentary","status":"completed"},
  {"type":"function_call","id":"fc_89e41fc1-e3ef-48ed-b5f8-26990b6edb57",
  "call_id":"call_89e41fc1-e3ef-48ed-b5f8-26990b6edb57","name":"tabs","arguments":"{}",
  "status":"completed"}]
  """

let recordedTurnTwo = """
  [{"type":"reasoning","id":"rs_6ae5825cc0b1557cde084926:rs_2bfdde15-ad86-4b5f-9909-2037da5a47e5",
  "summary":[],"status":"completed"},
  {"type":"function_call","id":"fc_750a233b-8b0c-42f6-a5ed-7b73ab63f8f5",
  "call_id":"call_750a233b-8b0c-42f6-a5ed-7b73ab63f8f5","name":"observe",
  "arguments":"{\\"tabId\\":\\"t1\\"}","status":"completed"}]
  """

private func items(_ json: String) -> [JSON] { JSON.parse(Data(json.utf8))?.array ?? [] }

private func result(_ callId: String, _ output: String) -> JSON {
  ["type": "function_call_output", "call_id": .string(callId), "output": .string(output)]
}

struct TranscriptTests {
  @Test func recordedTurnsReplayInOrderWithoutReasoningAndEveryCallAnswered() {
    var transcript = Transcript(prompt: "Task: click Count")
    transcript.add(output: items(recordedTurnOne))
    transcript.add(results: [result("call_89e41fc1-e3ef-48ed-b5f8-26990b6edb57", "tabs ok")])
    transcript.add(output: items(recordedTurnTwo))
    transcript.add(results: [result("call_750a233b-8b0c-42f6-a5ed-7b73ab63f8f5", "page ok")])

    let all = transcript.items
    #expect(all.count == 6)
    #expect(all[0]["role"] == "user" && all[0]["content"] == "Task: click Count")
    #expect(
      all.map { $0["type"]?.string ?? "user" } == [
        "user", "message", "function_call", "function_call_output", "function_call",
        "function_call_output",
      ])
    #expect(!all.contains { $0["type"] == "reasoning" })
    #expect(!all.contains { $0["id"]?.string?.hasPrefix("rs_") == true && $0["type"] != "message" })
    #expect(all[1]["phase"] == "commentary")
    #expect(all[1]["content"]?[0]?["text"] == "I'll observe your page and click Count once.")

    let calls = all.filter { $0["type"] == "function_call" }.compactMap { $0["call_id"] }
    let answers = all.filter { $0["type"] == "function_call_output" }.compactMap { $0["call_id"] }
    #expect(calls == answers)
  }

  @Test func itemsAreKeptAsReceivedAndOtherTypesAreDropped() {
    var transcript = Transcript(prompt: "go")
    let call = items(recordedTurnOne)[2]
    transcript.add(output: [["type": "computer_call", "call_id": "c"], call])
    #expect(transcript.items.count == 2)
    #expect(transcript.items[1] == call)
  }
}
