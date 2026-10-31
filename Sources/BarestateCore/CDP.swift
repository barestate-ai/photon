import Foundation

public struct CDPEvent: Sendable, Equatable {
  public let method: String
  public let params: JSON

  public init(method: String, params: JSON) {
    self.method = method
    self.params = params
  }
}

public enum CDPError: Error, Equatable, Sendable {
  case timeout
  case closed
  case sendFailed
  case remote(code: Int, message: String)
}

public protocol CDPTransport: Sendable {
  /// The id is allocated inside; a call that gets no reply fails after 10 s.
  func send(_ method: String, _ params: JSON) async throws -> JSON
  var events: AsyncStream<CDPEvent> { get }
}

/// Id matching, timeouts and event delivery for one DevTools connection. The wire itself is a
/// closure, so the same logic serves the CEF browser and a fake in tests. Runs on the main actor,
/// where CEF delivers every reply.
@MainActor
public final class CDPChannel: CDPTransport {
  public nonisolated let events: AsyncStream<CDPEvent>

  private struct Pending {
    let reply: AsyncThrowingStream<JSON, Error>.Continuation
    let timer: Task<Void, Never>
  }

  private let eventSink: AsyncStream<CDPEvent>.Continuation
  private let write: (String) -> Bool
  private let timeout: Duration
  private var nextId = 1
  private var pending: [Int: Pending] = [:]
  private var closed = false

  public init(timeout: Duration = .seconds(10), write: @escaping (String) -> Bool) {
    (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
    self.timeout = timeout
    self.write = write
  }

  public func send(_ method: String, _ params: JSON) async throws -> JSON {
    try await submit(method, params)()
  }

  /// Writes the message now and returns the wait for its reply, so several messages can be put on
  /// the wire in one run of main-actor code, with nothing able to interleave between them.
  public func submit(_ method: String, _ params: JSON) -> () async throws -> JSON {
    let (replies, reply) = AsyncThrowingStream.makeStream(of: JSON.self)
    let wait: () async throws -> JSON = {
      for try await value in replies { return value }
      throw CDPError.closed
    }
    if closed {
      reply.finish(throwing: CDPError.closed)
      return wait
    }
    let id = nextId
    nextId += 1
    let message: JSON = ["id": .number(Double(id)), "method": .string(method), "params": params]
    let timer = Task { [weak self, timeout] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.finish(id, .failure(CDPError.timeout))
    }
    // CEF answers browser-handled methods (Page.getNavigationHistory) inside the write call, so
    // the call must already be pending by then.
    pending[id] = Pending(reply: reply, timer: timer)
    if !write(message.serialized()) { finish(id, .failure(CDPError.sendFailed)) }
    return wait
  }

  /// One raw DevTools message: a reply (it has an "id") or an event (it has a "method").
  public func receive(_ message: Data) {
    guard let message = JSON.parse(message) else { return }
    if let id = message["id"]?.int {
      if let error = message["error"] {
        finish(
          id,
          .failure(
            CDPError.remote(
              code: error["code"]?.int ?? -1, message: error["message"]?.string ?? "unknown error")
          ))
      } else {
        finish(id, .success(message["result"] ?? .object([:])))
      }
    } else if let method = message["method"]?.string {
      eventSink.yield(CDPEvent(method: method, params: message["params"] ?? .object([:])))
    }
  }

  /// The browser is gone: nothing pending can be answered.
  public func close() {
    closed = true
    for id in Array(pending.keys) { finish(id, .failure(CDPError.closed)) }
    eventSink.finish()
  }

  private func finish(_ id: Int, _ outcome: Result<JSON, Error>) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer.cancel()
    switch outcome {
    case .success(let value):
      entry.reply.yield(value)
      entry.reply.finish()
    case .failure(let error):
      entry.reply.finish(throwing: error)
    }
  }
}
