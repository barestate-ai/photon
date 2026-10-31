import BarestateCore
import Foundation
import Network

/// A phone's event stream as the app sees it: one socket connection that subscribes under the
/// phone's session, relays the app's events, and asks for a screencast of the tab of each running
/// phone task while it is subscribed.
@MainActor
final class PhoneStream {
  private static let subscribeId = 1
  private static let maxBuffer = 8 << 20

  private let connection: NWConnection
  private let session: String
  private let owns: (String) -> Bool
  private var buffer = Data()
  private var ready = false
  /// Events that arrive before the subscribe reply.
  private var held: [Data] = []
  private var tabs: [String: String] = [:]
  private var casting: Set<String> = []
  private var nextId = 2
  private var ended = false

  /// Called once the app has taken the subscription.
  var onReady: (() -> Void)?
  /// One server-sent event, and whether it is a screencast frame.
  var onEvent: ((Data, Bool) -> Void)?
  /// The app closed the stream or cannot be reached.
  var onEnd: (() -> Void)?

  init(path: String, session: String, owns: @escaping (String) -> Bool) {
    connection = NWConnection(to: .unix(path: path), using: .tcp)
    self.session = session
    self.owns = owns
  }

  func start() {
    connection.stateUpdateHandler = { [self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready:
          send(
            "events.subscribe", ["session": .string(session)], id: Self.subscribeId)
          receive()
        case .waiting, .failed: end()
        default: break
        }
      }
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      MainActor.assumeIsolated { if self?.ready == false { self?.end() } }
    }
  }

  func stop() {
    ended = true
    connection.cancel()
  }

  private func send(_ method: String, _ params: [String: JSON], id: Int? = nil) {
    var message: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
    message["params"] = .object(params)
    message["id"] = .number(Double(id ?? nextId))
    if id == nil { nextId += 1 }
    connection.send(
      content: Data((JSON.object(message).serialized() + "\n").utf8), completion: .idempotent)
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
      [self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard !ended else { return }
        if let data { buffer.append(data) }
        while let newline = buffer.firstIndex(of: 0x0A) {
          handle(Data(buffer[..<newline]))
          buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if complete || error != nil || buffer.count > Self.maxBuffer { end() } else { receive() }
      }
    }
  }

  private func handle(_ line: Data) {
    if ready { return relay(line) }
    if JSON.parse(line)?["id"]?.int == Self.subscribeId {
      ready = true
      onReady?()
      for earlier in held { relay(earlier) }
      held = []
    } else {
      held.append(line)
    }
  }

  private func relay(_ line: Data) {
    follow(line)
    if let event = PhoneAPI.sse(from: line) { onEvent?(event.bytes, event.frame) }
  }

  /// Keeps a screencast running on exactly the tabs of this phone's tasks that are running.
  private func follow(_ line: Data) {
    guard let message = JSON.parse(line), message["method"] == "run.update",
      let params = message["params"], let runId = params["runId"]?.string, owns(runId)
    else { return }
    let running = params["state"]?.string.flatMap(RunState.init(rawValue:))?.isInProgress == true
    tabs[runId] = running ? params["tabId"]?.string : nil
    let wanted = Set(tabs.values)
    for tabId in wanted.subtracting(casting) { send("screencast.start", ["tabId": .string(tabId)]) }
    for tabId in casting.subtracting(wanted) { send("screencast.stop", ["tabId": .string(tabId)]) }
    casting = wanted
  }

  private func end() {
    guard !ended else { return }
    ended = true
    connection.cancel()
    onEnd?()
  }
}
