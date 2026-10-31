import CryptoKit
import Foundation

public struct Pairing: Codable, Equatable, Sendable {
  /// SHA-256 of the token, lowercase hex. The token itself is never stored.
  public let hash: String
  public let label: String
  public let created: String
}

/// The paired devices in `<data-dir>/pairing.json` (architecture §8). The app writes it; the
/// gateway reads it on every request, so a new pairing works and a revoked one stops at once.
public struct PairingStore: Sendable {
  private struct File: Codable { var pairings: [Pairing] }

  public let path: String

  public init(path: String) { self.path = path }

  public static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func list() -> [Pairing] {
    guard let data = FileManager.default.contents(atPath: path),
      let file = try? JSONDecoder().decode(File.self, from: data)
    else { return [] }
    return file.pairings
  }

  /// Stores a new pairing and returns its token, which only the caller ever sees.
  public func mint(label: String, now: Date = Date()) throws -> String {
    var generator = SystemRandomNumberGenerator()
    let token = (0..<32).map { _ in
      String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
    }
    .joined()
    let created = ISO8601DateFormatter().string(from: now)
    try save(list() + [Pairing(hash: Self.hash(token), label: label, created: created)])
    return token
  }

  public func revoke(hash: String) throws {
    try save(list().filter { $0.hash != hash })
  }

  /// Compares against every stored hash without stopping at a match.
  public func authenticate(_ token: String) -> Pairing? {
    let presented = Array(Self.hash(token).utf8)
    var found: Pairing?
    for pairing in list() where Self.equal(presented, Array(pairing.hash.utf8)) { found = pairing }
    return found
  }

  private static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
  }

  /// When each pairing last made an authenticated request, by hash. The gateway is the only
  /// writer: a file apart from `pairing.json`, so its write can never undo the app's revoke.
  public func lastSeen() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: seenPath),
      let seen = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return seen
  }

  public func markSeen(hash: String, now: Date = Date()) {
    let known = Set(list().map(\.hash))
    guard known.contains(hash) else { return }
    var seen = lastSeen().filter { known.contains($0.key) }
    seen[hash] = ISO8601DateFormatter().string(from: now)
    if let data = try? JSONEncoder().encode(seen) { try? write(data, to: seenPath) }
  }

  private var seenPath: String { (path as NSString).deletingPathExtension + "-seen.json" }

  private func save(_ pairings: [Pairing]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try write(try encoder.encode(File(pairings: pairings)), to: path)
  }

  private func write(_ data: Data, to path: String) throws {
    let temporary = path + ".tmp"
    guard
      FileManager.default.createFile(
        atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    guard rename(temporary, path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
