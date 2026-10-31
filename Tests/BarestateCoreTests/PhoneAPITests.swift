import BarestateCore
import Foundation
import Testing

struct PhoneAPITests {
  private func prepared(_ route: String, _ body: String) -> PhoneAPI.Prepared {
    PhoneAPI.prepare(route: route, body: Data(body.utf8), session: "phone-ab12cd34")
  }

  private func line(_ route: String, _ body: String) -> JSON? {
    guard case .call(let line) = prepared(route, body) else { return nil }
    return JSON.parse(line)
  }

  @Test func aTaskStartsAPhoneRunBoundToTheSession() {
    let message = line("task", #"{"prompt":"  find the cheapest flight "}"#)
    #expect(message?["method"] == "run.start")
    let params = message?["params"]
    #expect(params?["prompt"] == "find the cheapest flight")
    #expect(params?["origin"] == "phone")
    #expect(params?["remoteSession"] == "phone-ab12cd34")
  }

  @Test func theOtherRoutesMapToTheirSocketMethods() {
    #expect(line("stop", #"{"runId":"r1"}"#)?["method"] == "run.stop")
    let takeover = line("takeover", #"{"runId":"r1"}"#)
    #expect(takeover?["params"]?["runId"] == "r1")
    #expect(takeover?["params"]?["remoteSession"] == "phone-ab12cd34")
    let approve = line("approve", #"{"approvalId":"a3","allow":true}"#)
    #expect(approve?["method"] == "approval.decide")
    #expect(approve?["params"]?["allow"] == true)
    #expect(approve?["params"]?["remoteSession"] == "phone-ab12cd34")
    let disconnect = line("disconnect", "")
    #expect(disconnect?["method"] == "remote.disconnect")
    #expect(disconnect?["params"]?["session"] == "phone-ab12cd34")
  }

  @Test func badInputIsRefusedHereAndNeverReachesTheApp() {
    let bad = PhoneAPI.Prepared.refuse(status: 400, error: "bad-request")
    #expect(prepared("task", "not json") == bad)
    #expect(prepared("task", #"{"prompt":"   "}"#) == bad)
    #expect(prepared("task", #"{"prompt":5}"#) == bad)
    #expect(prepared("task", #"{"prompt":"\#(String(repeating: "a", count: 5000))"}"#) == bad)
    #expect(prepared("stop", "{}") == bad)
    #expect(prepared("approve", #"{"approvalId":"a1"}"#) == bad)
    #expect(prepared("approve", #"{"approvalId":"a1","allow":"yes"}"#) == bad)
    #expect(prepared("nope", "{}") == .refuse(status: 404, error: "not-found"))
  }

  @Test func aReplyBecomesAStatusAndABody() {
    let ok = PhoneAPI.respond(Data(#"{"jsonrpc":"2.0","id":1,"result":{"runId":"r1"}}"#.utf8))
    #expect(ok.status == 200)
    #expect(JSON.parse(ok.body)?["runId"] == "r1")
    func failure(_ code: Int) -> Int {
      let text = #"{"jsonrpc":"2.0","id":1,"error":{"code":\#(code),"message":"no such run"}}"#
      return PhoneAPI.respond(Data(text.utf8)).status
    }
    #expect(failure(-32602) == 400)
    #expect(failure(-32000) == 404)
    let noSession = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"no-session"}}"#
    #expect(PhoneAPI.respond(Data(noSession.utf8)).status == 409)
    #expect(PhoneAPI.respond(Data("garbage".utf8)).status == 502)
  }

  @Test func onlyTheNamedEventsAreRelayedAsServerSentEvents() {
    let frame = Data(
      #"{"jsonrpc":"2.0","method":"screencast.frame","params":{"tabId":"t2","data":"/9j/"}}"#.utf8)
    let relayed = PhoneAPI.sse(from: frame)
    #expect(relayed?.frame == true)
    let text = String(decoding: relayed?.bytes ?? Data(), as: UTF8.self)
    #expect(text.hasPrefix("event: screencast.frame\ndata: {"))
    #expect(text.hasSuffix("}\n\n"))
    #expect(text.contains(#""data":"\/9j\/""#) == false)

    let update = Data(#"{"jsonrpc":"2.0","method":"run.update","params":{"runId":"r1"}}"#.utf8)
    #expect(PhoneAPI.sse(from: update)?.frame == false)
    let reply = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
    #expect(PhoneAPI.sse(from: reply) == nil)
    let other = Data(#"{"jsonrpc":"2.0","method":"tabs","params":{}}"#.utf8)
    #expect(PhoneAPI.sse(from: other) == nil)
  }

  @Test func theSessionNamesTheTokenHashWithoutExposingIt() {
    let hash = String(repeating: "ab", count: 32)
    #expect(PhoneAPI.session(hash: hash) == "phone-abababab")
  }
}
