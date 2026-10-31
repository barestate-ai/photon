import Darwin
import Foundation

// stdio MCP server: newline-delimited JSON-RPC on stdin/stdout, forwarded to Photon's app.sock,
// which holds the MCP dispatcher. stdout carries protocol messages only; diagnostics go to stderr.

func diagnose(_ message: String) {
  FileHandle.standardError.write(Data("barestate-mcp: \(message)\n".utf8))
}

func socketPath() -> String {
  var path = ProcessInfo.processInfo.environment["BARESTATE_SOCKET"]
  var args = CommandLine.arguments.dropFirst()
  while let arg = args.popFirst() {
    if arg == "--stdio" { continue }
    if arg == "--socket", let value = args.popFirst() {
      path = value
    } else if arg.hasPrefix("--socket=") {
      path = String(arg.dropFirst("--socket=".count))
    } else {
      diagnose("usage: barestate-mcp [--stdio] [--socket <path>]")
      exit(64)
    }
  }
  return path
    ?? NSHomeDirectory() + "/Library/Application Support/Barestate/browser/app.sock"
}

final class Proxy: @unchecked Sendable {
  private let path: String
  /// Every request a transport sends is made as this session; Photon ignores any the client names.
  private let session = "mcp-" + UUID().uuidString.prefix(8).lowercased()
  private let lock = NSLock()
  private var fd: Int32 = -1
  /// Requests Photon has not answered yet, by id. Their ids are answered with an error if the
  /// connection drops first.
  private var owed: [String: Any] = [:]

  /// The only methods this transport forwards. Photon's socket also has methods that decide
  /// approvals and hand out control; a client must never reach those through here.
  private static let methods: Set<String> = [
    "initialize", "notifications/initialized", "ping", "server/discover", "tools/list",
    "tools/call",
  ]

  init(path: String) { self.path = path }

  private static func key(_ id: Any) -> String? {
    (try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed))
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Forwards one line. A request that cannot reach Photon is answered here with an error.
  func forward(_ line: String) {
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
      return emit(error: "Parse error", code: -32700, id: nil)
    }
    guard var message = parsed as? [String: Any] else {
      return emit(error: "Batches and bare values are not supported", code: -32600, id: nil)
    }
    let id = message["id"]
    if id is NSNull { return emit(error: "id must not be null", code: -32600, id: nil) }
    guard let method = message["method"] as? String else {
      return id == nil ? () : emit(error: "method required", code: -32600, id: id)
    }
    guard Self.methods.contains(method) else {
      return id == nil ? () : emit(error: "Method not found", code: -32601, id: id)
    }
    var params = message["params"] as? [String: Any] ?? [:]
    var meta = params["_meta"] as? [String: Any] ?? [:]
    meta["barestate/session"] = session
    params["_meta"] = meta
    message["params"] = params
    guard
      var out = try? JSONSerialization.data(
        withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return }
    out.append(0x0A)
    let owedKey = id.flatMap(Self.key)
    lock.lock()
    if let owedKey { owed[owedKey] = id }
    lock.unlock()
    if !send(out), let owedKey {
      lock.lock()
      owed[owedKey] = nil
      lock.unlock()
      emit(error: "Photon is not running or not listening at \(path)", id: id)
    }
  }

  /// Waits for replies still owed, up to `seconds`.
  func drain(seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      lock.lock()
      let count = owed.count
      lock.unlock()
      if count == 0 { return }
      usleep(20_000)
    }
  }

  private func send(_ data: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if fd < 0 { fd = connectSocket() }
    guard fd >= 0 else { return false }
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, data.count - offset)
      }
      if written < 0 && errno == EINTR { continue }
      if written <= 0 {
        close(fd)
        fd = -1
        return false
      }
      offset += written
    }
    return true
  }

  private func connectSocket() -> Int32 {
    let socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFd >= 0 else { return -1 }
    var on: Int32 = 1
    setsockopt(socketFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      close(socketFd)
      return -1
    }
    withUnsafeMutableBytes(of: &address.sun_path) {
      _ = memcpy($0.baseAddress!, bytes, bytes.count)
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(socketFd)
      return -1
    }
    Thread.detachNewThread { [self] in relay(socketFd) }
    return socketFd
  }

  /// Copies Photon's replies to stdout, one line each, until the socket closes.
  private func relay(_ socketFd: Int32) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = read(socketFd, &chunk, chunk.count)
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      buffer.append(contentsOf: chunk[..<count])
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex...newline]
        buffer = Data(buffer[buffer.index(after: newline)...])
        emitLine(Data(line))
        if let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let id = reply["id"], let owedKey = Self.key(id)
        {
          lock.lock()
          owed[owedKey] = nil
          lock.unlock()
        }
      }
    }
    lock.lock()
    if fd == socketFd {
      close(fd)
      fd = -1
    }
    let dropped = Array(owed.values)
    owed = [:]
    lock.unlock()
    for id in dropped { emit(error: "Photon closed the connection", id: id) }
  }

  private func emit(error message: String, code: Int = -32603, id: Any?) {
    let reply: [String: Any] = [
      "jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message],
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: reply, options: [.withoutEscapingSlashes])
    {
      emitLine(data + [0x0A])
    }
  }

  private let output = NSLock()

  /// A closed stdout ends the process quietly: nobody is left to read.
  private func emitLine(_ data: Data) {
    output.lock()
    defer { output.unlock() }
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes {
        Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, data.count - offset)
      }
      if written < 0 && errno == EINTR { continue }
      if written <= 0 { exit(0) }
      offset += written
    }
  }
}

// A closed stdout must surface as a failed write (which ends the process quietly), not a signal.
signal(SIGPIPE, SIG_IGN)
let proxy = Proxy(path: socketPath())
while let raw = readLine(strippingNewline: true) {
  let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
  if line.allSatisfy(\.isWhitespace) { continue }
  proxy.forward(line)
}
// stdin closed: the client is done. Replies already owed are still delivered, briefly.
proxy.drain(seconds: 1.5)
exit(0)
