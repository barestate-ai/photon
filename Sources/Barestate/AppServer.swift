import BarestateCore
import Darwin
import Dispatch
import Foundation

/// Newline-delimited JSON-RPC 2.0 on a Unix socket in the data dir. Accepting, reading and the
/// handlers run on the main queue; writing happens off it (`Writer`), so a client that stops reading
/// can never stall the app.
@MainActor
final class AppServer {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static let maxLine = 4 << 20

  private let path: String
  private let dispatcher: RPCDispatcher
  private var listener: DispatchSourceRead?
  private var connections: [ObjectIdentifier: Connection] = [:]

  init(path: String, dispatcher: RPCDispatcher) {
    self.path = path
    self.dispatcher = dispatcher
  }

  /// True when a running app already answers on `path`.
  static func isListening(at path: String) -> Bool {
    guard let existing = connect(path) else { return false }
    close(existing)
    return true
  }

  func start() throws {
    if Self.isListening(at: path) {
      throw Failure(description: "another instance is already listening on \(path)")
    }
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
    var address = Self.address(path)
    let oldMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(oldMask)
    guard bound == 0, listen(fd, 16) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw Failure(description: "bind \(path): \(message)")
    }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.accept(fd) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    listener = source
  }

  func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.close() }
    connections.removeAll()
    unlink(path)
  }

  private func accept(_ listenFd: Int32) {
    let fd = Darwin.accept(listenFd, nil, nil)
    guard fd >= 0 else {
      Log.error(.remote, "accept failed errno=\(errno)")
      return
    }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let connection = Connection(fd: fd, dispatcher: dispatcher, maxLine: Self.maxLine)
    let key = ObjectIdentifier(connection)
    connection.onClose = { [weak self] in self?.connections[key] = nil }
    connections[key] = connection
    Log.info(.remote, "connect clients=\(connections.count)")
  }

  private static func address(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      path.utf8CString.withUnsafeBytes { source in
        _ = memcpy(
          destination.baseAddress!, source.baseAddress!,
          min(source.count, destination.count - 1))
      }
    }
    return address
  }

  private static func connect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = address(path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result == 0 { return fd }
    close(fd)
    return nil
  }
}

/// Writes one client's lines on its own serial queue. The main actor only queues; a client that
/// stops reading blocks this queue and nothing else, and one that makes no progress for
/// `stall` seconds is dropped.
private final class Writer: @unchecked Sendable {
  private static let stall = 10.0

  private let fd: Int32
  private let queue = DispatchQueue(label: "barestate.appserver.write")
  private let lock = NSLock()
  private var pending = OutboundQueue()
  private var draining = false
  private var dead = false
  private let failed: @Sendable () -> Void

  init(fd: Int32, failed: @escaping @Sendable () -> Void) {
    self.fd = fd
    self.failed = failed
  }

  /// False when the client is too far behind for this line.
  func enqueue(_ line: Data, frame: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !dead else { return true }
    if pending.push(line, frame: frame) == .overflow { return false }
    if !draining {
      draining = true
      queue.async { self.drain() }
    }
    return true
  }

  /// Fails any write in progress at once; the descriptor itself closes after it (`release`).
  func stop() {
    lock.lock()
    dead = true
    lock.unlock()
    shutdown(fd, SHUT_RDWR)
  }

  func release() {
    let fd = fd
    queue.async { Darwin.close(fd) }
  }

  private func next() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if !dead, let line = pending.pop() { return line }
    draining = false
    return nil
  }

  private func drain() {
    while let line = next() {
      if !write(line) {
        lock.lock()
        let wasDead = dead
        dead = true
        draining = false
        lock.unlock()
        if !wasDead { failed() }
        return
      }
    }
  }

  private func write(_ data: Data) -> Bool {
    var offset = 0
    var deadline = Date().addingTimeInterval(Self.stall)
    while offset < data.count {
      let written = data.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
      }
      if written > 0 {
        offset += written
        deadline = Date().addingTimeInterval(Self.stall)
      } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
        var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        poll(&pollFd, 1, 200)
        if Date() > deadline { return false }
      } else {
        return false
      }
    }
    return true
  }
}

@MainActor
private final class Connection {
  var onClose: (() -> Void)?

  private let dispatcher: RPCDispatcher
  private let maxLine: Int
  private let fd: Int32
  private var source: DispatchSourceRead?
  private var buffer = Data()
  private var closed = false
  private var writer: Writer!
  private var peer: RPCPeer!

  init(fd: Int32, dispatcher: RPCDispatcher, maxLine: Int) {
    self.fd = fd
    self.dispatcher = dispatcher
    self.maxLine = maxLine
    writer = Writer(fd: fd) { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.writeFailed() } }
    }
    peer = RPCPeer(
      send: { [weak self] line, frame in self?.send(line, frame: frame) },
      disconnect: { [weak self] in self?.close() })
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.readable() }
    }
    let writer = writer!
    source.setCancelHandler { writer.release() }
    source.resume()
    self.source = source
  }

  func close() {
    guard !closed else { return }
    closed = true
    Log.info(.remote, "disconnect")
    writer.stop()
    source?.cancel()
    source = nil
    peer.closed()
    onClose?()
  }

  private func writeFailed() {
    Log.error(.remote, "write failed or stalled; closing")
    close()
  }

  private func send(_ line: Data, frame: Bool) {
    guard !closed else { return }
    var out = line
    out.append(0x0A)
    if !writer.enqueue(out, frame: frame) {
      Log.error(.remote, "client is not reading; closing")
      close()
    }
  }

  private func readable() {
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    let count = read(fd, &chunk, chunk.count)
    if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
      close()
      return
    }
    if count > 0 { buffer.append(contentsOf: chunk[..<count]) }
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer = Data(buffer[buffer.index(after: newline)...])
      if !line.isEmpty { respond(to: Data(line)) }
    }
    if buffer.count > maxLine {
      Log.error(.remote, "line over \(maxLine) bytes; closing")
      close()
    }
  }

  private func respond(to line: Data) {
    Task { @MainActor in
      let reply = await RPCContext.$peer.withValue(peer) { await dispatcher.handle(line: line) }
      if let reply { send(reply, frame: false) }
    }
  }
}
