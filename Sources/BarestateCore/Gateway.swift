import Foundation

/// The request line and headers of one HTTP/1.1 request. Bodies are Content-Length only: a
/// message the gateway cannot frame the same way as a proxy in front of it is refused.
public struct HTTPHead: Equatable, Sendable {
  public enum Parsed: Equatable, Sendable {
    case incomplete
    case head(HTTPHead)
    case invalid(status: Int)
  }

  public static let maxHead = 16 << 10
  /// Headers that must appear once: a second copy is how a proxy and this parser would disagree.
  private static let single: Set<String> = [
    "host", "origin", "authorization", "content-length", "transfer-encoding",
  ]

  public let method: String
  /// The request target without its query.
  public let path: String
  /// Lowercased names.
  public let headers: [String: String]
  public let contentLength: Int
  /// Bytes the head took in the buffer, including the blank line.
  public let length: Int

  public static func parse(_ buffer: Data) -> Parsed {
    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      return buffer.count > maxHead ? .invalid(status: 431) : .incomplete
    }
    guard end.upperBound <= maxHead else { return .invalid(status: 431) }
    guard let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
      return .invalid(status: 400)
    }
    var lines = text.components(separatedBy: "\r\n")
    let request = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard request.count == 3, request[2].hasPrefix("HTTP/1."), request[1].hasPrefix("/") else {
      return .invalid(status: 400)
    }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
      let name = String(line[..<colon])
      guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
        return .invalid(status: 400)
      }
      let key = name.lowercased()
      if headers[key] != nil && single.contains(key) { return .invalid(status: 400) }
      headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil { return .invalid(status: 501) }
    var length = 0
    if let value = headers["content-length"] {
      guard !value.isEmpty, value.count <= 15, value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let parsed = Int(value)
      else { return .invalid(status: 400) }
      length = parsed
    }
    let path = request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    return .head(
      HTTPHead(
        method: String(request[0]), path: String(path), headers: headers, contentLength: length,
        length: end.upperBound))
  }
}

/// Which hosts and origins the gateway answers for (architecture §8).
public struct GatewayPolicy: Sendable {
  private let hosts: Set<String>

  public init(port: UInt16, publicHost: String?) {
    hosts = Set(
      (["127.0.0.1:\(port)", "localhost:\(port)"] + (publicHost.map { [$0] } ?? []))
        .map { $0.lowercased() })
  }

  /// 403 for a Host or Origin that is not ours, nil otherwise. This runs before any token check.
  public func rejects(_ head: HTTPHead) -> Int? {
    guard let host = head.headers["host"], hosts.contains(host.lowercased()) else { return 403 }
    guard let origin = head.headers["origin"]?.lowercased() else { return nil }
    for scheme in ["http://", "https://"] where origin.hasPrefix(scheme) {
      return hosts.contains(String(origin.dropFirst(scheme.count))) ? nil : 403
    }
    return 403
  }

  public static func bearer(_ head: HTTPHead) -> String? {
    guard let value = head.headers["authorization"], value.count > 7,
      value.prefix(7).lowercased() == "bearer "
    else { return nil }
    return String(value.dropFirst(7))
  }
}

public enum GatewayRoute: Equatable, Sendable {
  case health, phone, mcp, events
  case api(String)
  case notFound

  public init(path: String) {
    switch path {
    case "/__health": self = .health
    case "/": self = .phone
    case "/mcp": self = .mcp
    case "/api/events": self = .events
    default: self = path.hasPrefix("/api/") ? .api(String(path.dropFirst(5))) : .notFound
    }
  }

  public var needsToken: Bool {
    switch self {
    case .mcp, .events, .api: true
    case .health, .phone, .notFound: false
    }
  }
}

/// At most `limit` requests per `window` seconds for each key, at any moment: a burst cannot
/// borrow from the next second the way a refilling bucket would.
public struct SlidingWindowLimiter: Sendable {
  private let limit: Int
  private let window: Double
  private var hits: [String: [Double]] = [:]

  public init(limit: Int, window: Double) {
    self.limit = limit
    self.window = window
  }

  public mutating func allow(_ key: String, at now: Double) -> Bool {
    var recent = (hits[key] ?? []).filter { now - $0 < window }
    defer { hits[key] = recent }
    guard recent.count < limit else { return false }
    recent.append(now)
    return true
  }
}
