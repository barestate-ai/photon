import Foundation
import Network

/// One request line sent to Photon's socket, and (for a request, not a notification) its reply
/// line. Each exchange has its own connection, so no state is shared between remote clients.
@MainActor
final class Upstream {
  enum Result {
    case replied(Data)
    case sent
    case failed
  }

  private let connection: NWConnection
  private var buffer = Data()
  private var done: (@MainActor (Result) -> Void)?

  init(path: String) { connection = NWConnection(to: .unix(path: path), using: .tcp) }

  func exchange(
    _ line: Data, wantsReply: Bool, timeout: Double, done: @escaping @MainActor (Result) -> Void
  ) {
    self.done = done
    connection.stateUpdateHandler = { [self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready: send(line, wantsReply: wantsReply)
        case .waiting, .failed: finish(.failed)
        default: break
        }
      }
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      MainActor.assumeIsolated { self?.finish(.failed) }
    }
  }

  private func send(_ line: Data, wantsReply: Bool) {
    connection.send(
      content: line,
      completion: .contentProcessed { [self] error in
        MainActor.assumeIsolated {
          if error != nil {
            finish(.failed)
          } else if wantsReply {
            receive()
          } else {
            finish(.sent)
          }
        }
      })
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
      [self] data, _, complete, error in
      MainActor.assumeIsolated {
        if let data { buffer.append(data) }
        if let newline = buffer.firstIndex(of: 0x0A) {
          finish(.replied(Data(buffer[..<newline])))
        } else if complete || error != nil {
          finish(.failed)
        } else {
          receive()
        }
      }
    }
  }

  private func finish(_ result: Result) {
    guard let done else { return }
    self.done = nil
    buffer = Data()
    connection.cancel()
    done(result)
  }
}
