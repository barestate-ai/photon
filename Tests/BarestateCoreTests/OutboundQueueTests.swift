import BarestateCore
import Foundation
import Testing

struct OutboundQueueTests {
  private func data(_ text: String) -> Data { Data(text.utf8) }

  @Test func messagesLeaveInOrder() {
    var queue = OutboundQueue()
    #expect(queue.push(data("a"), frame: false) == .queued)
    #expect(queue.push(data("b"), frame: false) == .queued)
    #expect(queue.pop() == data("a"))
    #expect(queue.pop() == data("b"))
    #expect(queue.pop() == nil)
  }

  @Test func aFrameReplacesTheFrameStillWaiting() {
    var queue = OutboundQueue(maxMessages: 2, maxBytes: 100)
    #expect(queue.push(data("f1"), frame: true) == .queued)
    #expect(queue.push(data("m"), frame: false) == .queued)
    #expect(queue.push(data("f2"), frame: true) == .replacedFrame)
    #expect(queue.push(data("f3"), frame: true) == .replacedFrame)
    #expect([queue.pop(), queue.pop(), queue.pop()] == [data("m"), data("f3"), nil])
  }

  @Test func framesNeverOverflowAClientThatFallsBehind() {
    var queue = OutboundQueue(maxMessages: 1, maxBytes: 10)
    for _ in 0..<1000 {
      #expect(queue.push(Data(repeating: 1, count: 1 << 16), frame: true) != .overflow)
    }
  }

  @Test func otherMessagesOverflowByCountOrByBytes() {
    var count = OutboundQueue(maxMessages: 2, maxBytes: 100)
    #expect(count.push(data("a"), frame: false) == .queued)
    #expect(count.push(data("b"), frame: false) == .queued)
    #expect(count.push(data("c"), frame: false) == .overflow)

    var bytes = OutboundQueue(maxMessages: 10, maxBytes: 4)
    #expect(bytes.push(data("abc"), frame: false) == .queued)
    #expect(bytes.push(data("de"), frame: false) == .overflow)
  }

  @Test func draining_makes_room_again() {
    var queue = OutboundQueue(maxMessages: 1, maxBytes: 100)
    #expect(queue.push(data("a"), frame: false) == .queued)
    _ = queue.pop()
    #expect(queue.push(data("b"), frame: false) == .queued)
  }
}
