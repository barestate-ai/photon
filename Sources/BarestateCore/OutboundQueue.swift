import Foundation

/// What waits to be written to one socket client. Screencast frames are only worth their newest
/// copy, so a waiting frame is replaced and frames never overflow; any other message that does not
/// fit means the client is not reading and must be dropped.
public struct OutboundQueue: Sendable {
  public enum Push: Equatable, Sendable {
    case queued
    case replacedFrame
    case overflow
  }

  private struct Entry {
    let data: Data
    let frame: Bool
  }

  private let maxMessages: Int
  private let maxBytes: Int
  private var entries: [Entry] = []
  private var messageCount = 0
  private var messageBytes = 0

  public init(maxMessages: Int = 512, maxBytes: Int = 32 << 20) {
    self.maxMessages = maxMessages
    self.maxBytes = maxBytes
  }

  public mutating func push(_ data: Data, frame: Bool) -> Push {
    if frame {
      let waiting = entries.firstIndex { $0.frame }
      if let waiting { entries.remove(at: waiting) }
      entries.append(Entry(data: data, frame: true))
      return waiting == nil ? .queued : .replacedFrame
    }
    // A lone message bigger than the byte limit (a screenshot) still goes through an empty queue.
    if messageCount >= maxMessages || (messageCount > 0 && messageBytes + data.count > maxBytes) {
      return .overflow
    }
    entries.append(Entry(data: data, frame: false))
    messageCount += 1
    messageBytes += data.count
    return .queued
  }

  public mutating func pop() -> Data? {
    guard !entries.isEmpty else { return nil }
    let entry = entries.removeFirst()
    if !entry.frame {
      messageCount -= 1
      messageBytes -= entry.data.count
    }
    return entry.data
  }
}
