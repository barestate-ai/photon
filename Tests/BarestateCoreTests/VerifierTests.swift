import BarestateCore
import Foundation
import Testing

struct VerifierTests {
  private func dom(_ verified: Bool) -> DispatchOutcome {
    DispatchOutcome(verified: verified, verdict: verified ? "state-changed" : "unchanged")
  }

  @Test func theVerdictTableIsConfirmedFailedOrUnknown() {
    let yes = ModelVerdict.success("it changed")
    let no = ModelVerdict.failure("nothing moved")
    let gone = ModelVerdict.unavailable("unreachable")
    #expect(Verifier.decide(dom: dom(true), model: yes).state == .confirmed)
    #expect(Verifier.decide(dom: dom(false), model: no).state == .failed)
    #expect(Verifier.decide(dom: dom(true), model: no).state == .outcomeUnknown)
    #expect(Verifier.decide(dom: dom(false), model: yes).state == .outcomeUnknown)
    #expect(Verifier.decide(dom: dom(true), model: gone).state == .outcomeUnknown)
    #expect(Verifier.decide(dom: dom(false), model: gone).state == .outcomeUnknown)
  }

  @Test func eachNonConfirmedStateSaysWhy() {
    #expect(
      Verifier.decide(dom: dom(true), model: .failure("no change")).reason
        == "disagree: page read-back says success, model says failure (no change)")
    #expect(
      Verifier.decide(dom: dom(false), model: .failure("nothing")).reason
        == "read-back mismatch: unchanged (model: nothing)")
    #expect(
      Verifier.decide(dom: dom(true), model: .unavailable("unreachable")).reason
        == "model unavailable: unreachable")
    #expect(Verifier.decide(dom: dom(true), model: .success("ok")).reason == nil)
  }

  @Test func aModelVerdictIsStoredAsItsWordsAndReason() {
    #expect(ModelVerdict.success("the counter rose").stored == "success: the counter rose")
    #expect(ModelVerdict.failure("same").stored == "failure: same")
    #expect(ModelVerdict.unavailable("timeout").stored == "unavailable: timeout")
  }

  @Test func onlyTheStrictShapeIsAVerdict() {
    #expect(
      Verifier.verdict(text: #"{"reason":"counter 0 to 1","success":true}"#)
        == .success("counter 0 to 1"))
    #expect(Verifier.verdict(text: #"{"success":false,"reason":"same"}"#) == .failure("same"))
    for bad in [
      "", "yes", #"{"success":"true","reason":"x"}"#, #"{"success":true}"#,
      #"{"success":true,"reason":"x","extra":1}"#,
    ] {
      guard case .unavailable = Verifier.verdict(text: bad) else {
        Issue.record("accepted \(bad)")
        continue
      }
    }
  }

  @Test func theRequestCarriesTheIntentBothPicturesAndTheStrictSchema() throws {
    let request = Verifier.request(
      intent: #"click "Count""#, before: Data([1, 2]), after: Data([3, 4]))
    #expect(request.schema?.name == "verdict")
    let schema = try #require(request.schema?.schema)
    #expect(schema["additionalProperties"] == false)
    #expect(schema["required"]?.array?.compactMap(\.string) == ["success", "reason"])
    let parts = try #require(request.input.first?["content"]?.array)
    #expect(parts.first?["text"]?.string?.contains(#"click "Count""#) == true)
    let images = parts.compactMap { $0["image_url"]?.string }
    #expect(images == ["data:image/jpeg;base64,AQI=", "data:image/jpeg;base64,AwQ="])
    #expect(request.maxOutputTokens == 2000)
    #expect(request.effort == "minimal")
    #expect(!request.computer)
  }

  @Test func theInstructionsMakeThePicturesTheOnlyEvidence() {
    let request = Verifier.request(intent: "click", before: Data([1]), after: Data([2]))
    let words = request.instructions ?? ""
    for phrase in [
      "only evidence", "not what happened", "visibly differs", "look the same",
      "success is false", "what you saw",
    ] {
      #expect(words.contains(phrase), "missing: \(phrase)")
    }
  }

  /// Stands in for the network only; the reply shapes are the ones the API sent (library/models.md).
  private func verified(_ reply: String, ledger: String) async -> ModelVerdict {
    let transport: ModelTransport = { request, _ in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (Data(reply.utf8), response)
    }
    let client = ModelClient(
      environment: ["MODEL_API_KEY": "sk-test-secret-1234"], envFile: nil, keychain: { nil },
      ledger: SpendLedger(path: ledger), transport: transport)
    return await Verifier.verify(
      intent: "click", before: Data([1]), after: Data([2]), client: client)
  }

  private func reply(status: String, text: String, extra: String = "") -> String {
    """
    {"id":"resp_1","model":"muse-spark-1.3","status":"\(status)",\(extra)"output":[
    {"type":"reasoning"},{"type":"message","role":"assistant",
    "content":[{"type":"output_text","text":\(JSON.string(text).serialized())}]}],
    "usage":{"input_tokens":671,"output_tokens":600}}
    """
  }

  @Test func aReplyCutOffAtTheCapIsCutOffNotMalformedAndBilledOnce() async throws {
    let path = NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
    let cut = reply(
      status: "incomplete", text: #"{"success":true,"rea"#,
      extra: #""incomplete_details":{"reason":"max_output_tokens"},"#)
    #expect(await verified(cut, ledger: path) == .unavailable("verdict cut off"))
    let spent = JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(spent?["entries"]?.array?.count == 1)
  }

  @Test func aCutOffReplyIsNeverAVerdictEvenWhenItsTextParses() async {
    let whole = reply(
      status: "incomplete", text: #"{"success":true,"reason":"ok"}"#,
      extra: #""incomplete_details":{"reason":"max_output_tokens"},"#)
    #expect(
      await verified(whole, ledger: NSTemporaryDirectory() + "spend-\(UUID().uuidString).json")
        == .unavailable("verdict cut off"))
  }

  @Test func aFinishedReplyThatIsNotAVerdictStaysMalformed() async {
    let ledger = NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
    #expect(
      await verified(reply(status: "completed", text: "I think so"), ledger: ledger)
        == .unavailable("malformed verdict"))
    #expect(
      await verified(
        reply(status: "completed", text: #"{"success":true,"reason":"ok"}"#), ledger: ledger)
        == .success("ok"))
  }
}
