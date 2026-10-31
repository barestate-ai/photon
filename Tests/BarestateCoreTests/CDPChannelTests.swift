import BarestateCore
import Foundation
import Testing

@MainActor
struct CDPChannelTests {
  /// Records what the channel wrote so a test can answer in any order.
  final class Wire {
    var sent: [(id: Int, method: String, params: JSON)] = []
    var accepting = true

    func write(_ text: String) -> Bool {
      guard accepting, let message = JSON.parse(Data(text.utf8)),
        case .number(let id)? = message["id"],
        case .string(let method)? = message["method"]
      else { return false }
      sent.append((Int(id), method, message["params"] ?? .null))
      return true
    }
  }

  private func makeChannel(timeout: Duration = .seconds(10)) -> (CDPChannel, Wire) {
    let wire = Wire()
    return (CDPChannel(timeout: timeout) { wire.write($0) }, wire)
  }

  private func reply(_ channel: CDPChannel, _ id: Int, result: String) {
    channel.receive(Data(#"{"id":\#(id),"result":\#(result)}"#.utf8))
  }

  private func waitForSent(_ wire: Wire, _ count: Int) async {
    while wire.sent.count < count { await Task.yield() }
  }

  @Test func repliesAreMatchedByIdInAnyCompletionOrder() async throws {
    let (channel, wire) = makeChannel()
    async let metrics = channel.send("Page.getLayoutMetrics", [:])
    async let evaluate = channel.send("Runtime.evaluate", ["expression": "1+1"])
    async let history = channel.send("Page.getNavigationHistory", [:])
    await waitForSent(wire, 3)

    let ids = Dictionary(uniqueKeysWithValues: wire.sent.map { ($0.method, $0.id) })
    reply(channel, ids["Page.getNavigationHistory"]!, result: #"{"currentIndex":4}"#)
    reply(channel, ids["Page.getLayoutMetrics"]!, result: #"{"cssContentSize":{"width":9}}"#)
    reply(channel, ids["Runtime.evaluate"]!, result: #"{"result":{"value":2}}"#)

    #expect(try await metrics["cssContentSize"]?["width"] == .number(9))
    #expect(try await evaluate["result"]?["value"] == .number(2))
    #expect(try await history["currentIndex"] == .number(4))
  }

  @Test func anErrorReplyFailsOnlyItsCaller() async throws {
    let (channel, wire) = makeChannel()
    async let bad: JSON = channel.send("Nope.nope", [:])
    async let good = channel.send("Page.getFrameTree", [:])
    await waitForSent(wire, 2)
    for entry in wire.sent {
      if entry.method == "Nope.nope" {
        channel.receive(
          Data(
            #"{"id":\#(entry.id),"error":{"code":-32601,"message":"'Nope.nope' wasn't found"}}"#
              .utf8))
      } else {
        reply(channel, entry.id, result: "{}")
      }
    }
    #expect(try await good == .object([:]))
    do {
      _ = try await bad
      Issue.record("expected an error")
    } catch let error as CDPError {
      #expect(error == .remote(code: -32601, message: "'Nope.nope' wasn't found"))
    }
  }

  @Test func eventsAreDeliveredToTheSubscriber() async {
    let (channel, _) = makeChannel()
    channel.receive(Data(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"F"}}}"#.utf8))
    var iterator = channel.events.makeAsyncIterator()
    let event = await iterator.next()
    #expect(event?.method == "Page.frameNavigated")
    #expect(event?.params["frame"]?["id"] == .string("F"))
  }

  @Test func aSilentBrowserTimesOut() async {
    let (channel, wire) = makeChannel(timeout: .milliseconds(50))
    do {
      _ = try await channel.send("Page.getLayoutMetrics", [:])
      Issue.record("expected a timeout")
    } catch {
      #expect(error as? CDPError == .timeout)
    }
    #expect(wire.sent.count == 1)
  }

  @Test func aLateReplyAfterTheTimeoutIsDropped() async {
    let (channel, wire) = makeChannel(timeout: .milliseconds(20))
    _ = try? await channel.send("Page.getLayoutMetrics", [:])
    reply(channel, wire.sent[0].id, result: "{}")
  }

  @Test func closingFailsEveryPendingCall() async {
    let (channel, wire) = makeChannel()
    let first = Task { try await channel.send("A.a", [:]) }
    let second = Task { try await channel.send("B.b", [:]) }
    await waitForSent(wire, 2)
    channel.close()
    for call in [first, second] {
      do {
        _ = try await call.value
        Issue.record("expected closed")
      } catch {
        #expect(error as? CDPError == .closed)
      }
    }
  }

  @Test func aReplyDeliveredInsideTheWriteIsNotLost() async throws {
    final class Box { var channel: CDPChannel? }
    let box = Box()
    let channel = CDPChannel { text in
      let id = JSON.parse(Data(text.utf8))?["id"]?.int ?? 0
      box.channel?.receive(Data(#"{"id":\#(id),"result":{"ok":true}}"#.utf8))
      return true
    }
    box.channel = channel
    #expect(try await channel.send("Page.getNavigationHistory", [:])["ok"] == true)
  }

  @Test func aRejectedWriteThrowsAtOnce() async {
    let (channel, wire) = makeChannel()
    wire.accepting = false
    do {
      _ = try await channel.send("A.a", [:])
      Issue.record("expected sendFailed")
    } catch {
      #expect(error as? CDPError == .sendFailed)
    }
  }
}
