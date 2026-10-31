import BarestateCore
import Foundation
import Network

/// One remote connection: reads requests off it, checks them in the order of architecture §8
/// (Host and Origin, token, rate, then the route), and answers.
@MainActor
final class Client {
  private enum Phase {
    case head
    /// Waiting for the rest of an accepted `POST /mcp` or `POST /api/*` body.
    case body(HTTPHead, Pairing)
    /// Discarding what an answered request still owes, so the answer is not lost to a reset.
    case drain(remaining: Int)
    case stream
  }

  private static let idle = 30.0
  private static let drainCap = 8 << 20
  private static let streamTick = 5.0
  private static let reasons = [
    100: "Continue", 200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
    403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
    413: "Content Too Large",
    429: "Too Many Requests", 431: "Request Header Fields Too Large", 501: "Not Implemented",
    502: "Bad Gateway",
  ]

  var onClose: (() -> Void)?

  private let connection: NWConnection
  private unowned let gateway: Gateway
  private var buffer = Data()
  private var phase = Phase.head
  private var timer: DispatchWorkItem?
  private var holdsSession = false
  private var streamHash: String?
  private var phoneStream: PhoneStream?
  /// Events waiting for the phone to read them; frames are replaced by newer ones.
  private var outbox = OutboundQueue(maxMessages: 256, maxBytes: 4 << 20)
  private var sending = false
  private var endAfterFlush = false
  private var closed = false

  init(_ connection: NWConnection, gateway: Gateway) {
    self.connection = connection
    self.gateway = gateway
  }

  func start() {
    connection.stateUpdateHandler = { [self] state in
      MainActor.assumeIsolated {
        switch state {
        case .failed, .cancelled: close()
        default: break
        }
      }
    }
    connection.start(queue: .main)
    receive()
  }

  // MARK: Reading

  private func receive() {
    if case .stream = phase { arm(nil) } else { arm(Self.idle) }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
      [self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard error == nil, !closed else { return connection.cancel() }
        if let data { buffer.append(data) }
        if complete { return connection.cancel() }
        advance()
      }
    }
  }

  private func advance() {
    switch phase {
    case .head:
      switch HTTPHead.parse(buffer) {
      case .incomplete: receive()
      case .invalid(let status): reply(status, drain: 0, keepAlive: false)
      case .head(let head):
        buffer = Data(buffer.dropFirst(head.length))
        dispatch(head)
      }
    case .body(let head, let pairing):
      guard buffer.count >= head.contentLength else { return receive() }
      let body = buffer.prefix(head.contentLength)
      buffer = Data(buffer.dropFirst(head.contentLength))
      if case .api(let name) = GatewayRoute(path: head.path) {
        api(name, Data(body), pairing)
      } else {
        mcp(Data(body), pairing)
      }
    case .drain(let remaining):
      let left = remaining - buffer.count
      buffer = Data()
      if left <= 0 { return connection.cancel() }
      phase = .drain(remaining: left)
      receive()
    case .stream:
      buffer = Data()
      receive()
    }
  }

  private func next() {
    phase = .head
    if buffer.isEmpty { receive() } else { advance() }
  }

  /// Fires `connection.cancel()` if nothing arrives for `seconds`.
  private func arm(_ seconds: Double?) {
    timer?.cancel()
    timer = nil
    guard let seconds else { return }
    let item = DispatchWorkItem { [self] in MainActor.assumeIsolated { connection.cancel() } }
    timer = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
  }

  // MARK: Routing

  private func dispatch(_ head: HTTPHead) {
    let route = GatewayRoute(path: head.path)
    let owed = min(head.contentLength, Self.drainCap)
    let closing = head.headers["connection"]?.lowercased() == "close"
    func refuse(_ status: Int, _ headers: [String: String] = [:]) {
      if status == 413 {
        gateway.note("reject status=\(status) route=\(Self.label(route))")
      }
      reply(status, headers: headers, drain: owed, keepAlive: !closing)
    }
    if let status = gateway.policy.rejects(head) { return refuse(status) }
    var pairing: Pairing?
    if route.needsToken {
      guard let token = GatewayPolicy.bearer(head), let found = gateway.store.authenticate(token)
      else { return refuse(401, ["WWW-Authenticate": "Bearer"]) }
      guard gateway.allow(found) else { return refuse(429, ["Retry-After": "1"]) }
      gateway.markSeen(found)
      pairing = found
    }
    let method = head.method
    switch route {
    case .health:
      guard method == "GET" else { return refuse(405, ["Allow": "GET"]) }
      reply(200, type: "text/plain", body: Data("ok".utf8), drain: owed, keepAlive: !closing)
    case .phone, .notFound:
      guard let page = gateway.pages[head.path] else { return refuse(404) }
      guard method == "GET" else { return refuse(405, ["Allow": "GET"]) }
      reply(
        200, type: page.type, headers: Gateway.pageHeaders, body: page.body, drain: owed,
        keepAlive: !closing)
    case .api(let name):
      guard method == "POST" else { return refuse(405, ["Allow": "POST"]) }
      guard Gateway.apiRoutes.contains(name), let pairing else { return refuse(404) }
      guard head.contentLength <= Gateway.maxApiBody else { return refuse(413) }
      guard gateway.hasStream(pairing) else {
        return reply(
          409, body: Data(#"{"error":"no-session"}"#.utf8), drain: owed, keepAlive: !closing)
      }
      phase = .body(head, pairing)
      advance()
    case .events:
      guard method == "GET" else { return refuse(405, ["Allow": "GET"]) }
      guard let pairing, gateway.reserveSession() else { return refuse(429, ["Retry-After": "1"]) }
      holdsSession = true
      stream(pairing)
    case .mcp:
      guard method == "POST", let pairing else { return refuse(405, ["Allow": "POST"]) }
      guard head.contentLength <= Gateway.maxBody else { return refuse(413) }
      // Reserved before the body is read: a slow upload holds its slot.
      guard gateway.reserveSession() else { return refuse(429, ["Retry-After": "1"]) }
      holdsSession = true
      if head.headers["tailscale-funnel-request"] != nil { gateway.note("mcp via=funnel") }
      if head.headers["expect"]?.lowercased() == "100-continue", buffer.count < head.contentLength {
        write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
      }
      phase = .body(head, pairing)
      advance()
    }
  }

  private static func label(_ route: GatewayRoute) -> String {
    switch route {
    case .health: "health"
    case .phone: "phone"
    case .mcp: "mcp"
    case .events: "events"
    case .api: "api"
    case .notFound: "other"
    }
  }

  // MARK: MCP

  private func mcp(_ body: Data, _ pairing: Pairing) {
    arm(nil)
    let session = "http-" + pairing.hash.prefix(8)
    switch MCPBridge.prepare(body, session: session) {
    case .reply(let data): answer(200, data)
    case .accepted: answer(202, Data())
    case .forward(let line, let id):
      Upstream(path: gateway.socket).exchange(line, wantsReply: id != nil, timeout: 60) {
        [self] result in
        switch result {
        case .replied(let data): answer(200, data)
        case .sent: answer(202, Data())
        case .failed:
          gateway.note("upstream failed", level: "error")
          let error = MCPBridge.errorBody(
            "Photon is not running or did not answer", code: -32603, id: id)
          answer(502, Data(error.utf8))
        }
      }
    }
  }

  private func answer(_ status: Int, _ body: Data) {
    releaseSession()
    reply(status, body: body, drain: 0, keepAlive: true)
  }

  // MARK: Phone API

  private func api(_ name: String, _ body: Data, _ pairing: Pairing) {
    arm(nil)
    guard gateway.hasStream(pairing) else {
      return reply(
        409, body: Data(#"{"error":"no-session"}"#.utf8), drain: 0, keepAlive: true)
    }
    let session = PhoneAPI.session(hash: pairing.hash)
    switch PhoneAPI.prepare(route: name, body: body, session: session) {
    case .refuse(let status, let error):
      let body = Data(JSON.object(["error": .string(error)]).serialized().utf8)
      reply(status, body: body, drain: 0, keepAlive: true)
    case .call(let line):
      Upstream(path: gateway.socket).exchange(line, wantsReply: true, timeout: 60) {
        [self] result in
        guard case .replied(let data) = result else {
          gateway.note("upstream failed", level: "error")
          return reply(
            502, body: Data(#"{"error":"bad-gateway"}"#.utf8), drain: 0, keepAlive: true)
        }
        let answer = PhoneAPI.respond(data)
        if answer.status == 200 {
          if name == "task", let run = JSON.parse(answer.body)?["runId"]?.string {
            gateway.started(run: run, by: pairing)
          }
          if name == "disconnect" { _ = gateway.closeStreams(pairing) }
        }
        gateway.note("api route=\(name) status=\(answer.status)")
        reply(answer.status, body: answer.body, drain: 0, keepAlive: true)
      }
    }
  }

  // MARK: Events

  /// The phone's event stream. The headers go out at once; the app's events follow once it has
  /// taken the subscription. Ends when the token is revoked, the client leaves, or the app
  /// closes the session.
  private func stream(_ pairing: Pairing) {
    phase = .stream
    streamHash = pairing.hash
    let phone = PhoneStream(
      path: gateway.socket, session: PhoneAPI.session(hash: pairing.hash)
    ) { [gateway] in gateway.owns(run: $0, hash: pairing.hash) }
    phoneStream = phone
    phone.onReady = { [self] in emit(Data(": connected\n\n".utf8)) }
    phone.onEvent = { [self] bytes, frame in emit(bytes, frame: frame) }
    phone.onEnd = { [self] in endStream() }
    gateway.opened(self, hash: pairing.hash)
    gateway.note("session open token=\(pairing.hash.prefix(8)) sessions=\(gateway.sessions)")
    write(
      Data(
        ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
          + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n").utf8))
    phone.start()
    arm(nil)
    schedule()
    receive()
  }

  /// Tells the phone why, then closes once that has been written.
  func endStream() {
    guard !endAfterFlush, !closed else { return }
    endAfterFlush = true
    if let hash = streamHash { gateway.closed(self, hash: hash) }
    emit(Data("event: disconnected\ndata: {}\n\n".utf8))
  }

  private func emit(_ bytes: Data, frame: Bool = false) {
    if outbox.push(bytes, frame: frame) == .overflow {
      gateway.note("stream not reading", level: "error")
      return connection.cancel()
    }
    pump()
  }

  private func pump() {
    guard !sending, !closed else { return }
    guard let next = outbox.pop() else {
      if endAfterFlush { connection.cancel() }
      return
    }
    sending = true
    connection.send(
      content: next,
      completion: .contentProcessed { [self] error in
        MainActor.assumeIsolated {
          sending = false
          if error != nil { connection.cancel() } else { pump() }
        }
      })
  }

  private func schedule() {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamTick) { [self] in
      MainActor.assumeIsolated { tick() }
    }
  }

  private func tick() {
    guard case .stream = phase, !closed else { return }
    guard let hash = streamHash, gateway.store.list().contains(where: { $0.hash == hash }) else {
      gateway.note("session revoked")
      return connection.cancel()
    }
    emit(Data(": keepalive\n\n".utf8))
    schedule()
  }

  // MARK: Writing

  private func reply(
    _ status: Int, type: String = "application/json", headers: [String: String] = [:],
    body: Data = Data(), drain: Int, keepAlive: Bool
  ) {
    var lines = ["HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")"]
    lines.append("Content-Length: \(body.count)")
    if !body.isEmpty { lines.append("Content-Type: \(type)") }
    lines += ["Cache-Control: no-store", "X-Content-Type-Options: nosniff"]
    let closing = drain > 0 || !keepAlive
    if closing { lines.append("Connection: close") }
    for (name, value) in headers { lines.append("\(name): \(value)") }
    arm(nil)
    connection.send(
      content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body,
      completion: .contentProcessed { [self] error in
        MainActor.assumeIsolated {
          guard error == nil else { return connection.cancel() }
          guard closing else { return next() }
          let left = drain - buffer.count
          buffer = Data()
          if left <= 0 { return connection.cancel() }
          phase = .drain(remaining: left)
          receive()
        }
      })
  }

  private func releaseSession() {
    guard holdsSession else { return }
    holdsSession = false
    gateway.releaseSession()
  }

  private func write(_ data: Data) {
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  private func close() {
    guard !closed else { return }
    closed = true
    arm(nil)
    connection.cancel()
    if let hash = streamHash {
      gateway.note("session close sessions=\(gateway.sessions - 1)")
      phoneStream?.stop()
      gateway.closed(self, hash: hash)
    }
    releaseSession()
    onClose?()
  }
}
