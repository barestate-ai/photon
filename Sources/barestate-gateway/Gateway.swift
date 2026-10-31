import BarestateCore
import Foundation
import Network

/// Everything the clients share: who may come in, how many, and where Photon listens.
@MainActor
final class Gateway {
  static let maxBody = 4 << 20
  static let maxSessions = 8
  private static let seenEvery = 30.0
  static let apiRoutes: Set<String> = ["task", "stop", "approve", "takeover", "disconnect"]
  static let maxApiBody = 64 << 10
  private static let types = [
    "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
    "js": "text/javascript; charset=utf-8", "ttf": "font/ttf",
  ]
  /// Nothing but its own files may run or load: the page holds a token.
  static let pageHeaders = [
    "Content-Security-Policy":
      "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; "
      + "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; "
      + "frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
  ]

  let policy: GatewayPolicy
  let store: PairingStore
  let socket: String
  /// The phone page's files by request path, read once at start. `/` is index.html.
  let pages: [String: (type: String, body: Data)]
  private let log: LogFile?
  private var limiter = SlidingWindowLimiter(limit: 30, window: 1)
  private var clients: [ObjectIdentifier: Client] = [:]
  private var seenAt: [String: Double] = [:]
  /// Open event streams and MCP requests in flight.
  private(set) var sessions = 0
  /// A token's open event streams: a phone has a session while it has one.
  private var streams: [String: [ObjectIdentifier: Client]] = [:]
  /// The runs each token started, so their tabs can be streamed to it.
  private var runs: [String: Set<String>] = [:]

  init(options: Options) {
    policy = GatewayPolicy(port: options.port, publicHost: options.publicHost)
    socket = options.socket
    var pages: [String: (type: String, body: Data)] = [:]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: options.phoneDir)) ?? []
    for name in names {
      let type = Self.types[(name as NSString).pathExtension]
      guard let type, let body = FileManager.default.contents(atPath: options.phoneDir + "/" + name)
      else { continue }
      pages[name == "index.html" ? "/" : "/" + name] = (type, body)
    }
    if pages["/"] == nil { warn("no index.html in \(options.phoneDir); GET / will be 404") }
    self.pages = pages
    let dataDir = (options.socket as NSString).deletingLastPathComponent
    store = PairingStore(path: dataDir + "/pairing.json")
    // Shares the app's photon.log; the app rotates it, and `cap: .max` makes this writer follow.
    log = LogFile(path: dataDir + "/logs/photon.log", cap: .max)
    if log == nil { warn("no log file under \(dataDir)/logs") }
  }

  /// Ids, counts and status codes only: never a token, a path or a request body.
  func note(_ message: String, level: String = "info") {
    log?.append(level: level, category: "remote", message: "gateway " + message)
  }

  func accept(_ connection: NWConnection) {
    let client = Client(connection, gateway: self)
    let key = ObjectIdentifier(client)
    clients[key] = client
    client.onClose = { [weak self] in self?.clients[key] = nil }
    client.start()
  }

  func allow(_ pairing: Pairing) -> Bool {
    limiter.allow(pairing.hash, at: ProcessInfo.processInfo.systemUptime)
  }

  /// Settings shows when a device last came; once per half minute is enough for that.
  func markSeen(_ pairing: Pairing) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - (seenAt[pairing.hash] ?? -Self.seenEvery) >= Self.seenEvery else { return }
    seenAt[pairing.hash] = now
    store.markSeen(hash: pairing.hash)
  }

  func reserveSession() -> Bool {
    guard sessions < Self.maxSessions else { return false }
    sessions += 1
    return true
  }

  func releaseSession() { sessions -= 1 }

  func hasStream(_ pairing: Pairing) -> Bool { !(streams[pairing.hash]?.isEmpty ?? true) }

  func opened(_ client: Client, hash: String) {
    streams[hash, default: [:]][ObjectIdentifier(client)] = client
  }

  func closed(_ client: Client, hash: String) {
    streams[hash]?[ObjectIdentifier(client)] = nil
    if streams[hash]?.isEmpty == true { streams[hash] = nil }
  }

  /// Ends every stream of the token; the phone must open a new one before its next action.
  func closeStreams(_ pairing: Pairing) -> Int {
    let open = Array((streams[pairing.hash] ?? [:]).values)
    for client in open { client.endStream() }
    return open.count
  }

  func started(run id: String, by pairing: Pairing) { runs[pairing.hash, default: []].insert(id) }

  func owns(run id: String, hash: String) -> Bool { runs[hash]?.contains(id) == true }
}

func warn(_ message: String) {
  FileHandle.standardError.write(Data("barestate-gateway: \(message)\n".utf8))
}

struct Options {
  var port: UInt16 = 47820
  var socket =
    ProcessInfo.processInfo.environment["BARESTATE_SOCKET"]
    ?? NSHomeDirectory() + "/Library/Application Support/Barestate/browser/app.sock"
  /// The Funnel host and port that Host and Origin may name besides loopback.
  var publicHost: String?
  /// Exit when this process does, so a crashed app never leaves the door open.
  var parent: pid_t?
  /// Remove the app's `/barestate` Funnel handler when the parent exits (set only when it mounted one).
  var unmountFunnelOnExit = false
  /// Where the phone page's files are; relative paths resolve against the working directory.
  var phoneDir = "Resources/phone"

  init(_ arguments: [String]) {
    var args = arguments.dropFirst()
    while let arg = args.popFirst() {
      if arg == "--unmount-funnel-on-exit" {
        unmountFunnelOnExit = true
        continue
      }
      switch (arg, args.popFirst()) {
      case ("--port", let value?) where UInt16(value) != nil: port = UInt16(value)!
      case ("--socket", let value?): socket = value
      case ("--public-host", let value?): publicHost = value
      case ("--parent", let value?) where pid_t(value) != nil: parent = pid_t(value)
      case ("--phone-dir", let value?): phoneDir = value
      default:
        warn(
          "usage: barestate-gateway [--port <n>] [--socket <path>] [--public-host <host:port>] [--parent <pid>] [--unmount-funnel-on-exit] [--phone-dir <path>]"
        )
        exit(64)
      }
    }
  }
}
