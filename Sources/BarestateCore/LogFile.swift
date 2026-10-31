import Darwin
import Foundation

/// An append-only text log with one rotated generation (`<path>.1`). Rotation reopens onto the
/// same descriptor number so a signal handler can keep writing to the number it saved. A second
/// process may share the file (the gateway); `cap: .max` makes it follow rotation, never cause it.
public final class LogFile: @unchecked Sendable {
  public static let defaultCap = 5 << 20
  /// Bounds one entry, so a single huge message cannot exceed the file cap.
  static let maxMessage = 8 << 10

  public let path: String
  public let descriptor: Int32
  private let cap: Int
  private let lock = NSLock()
  private var size: Int
  private let timestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  public init?(path: String, cap: Int = LogFile.defaultCap) {
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    self.path = path
    self.cap = cap
    descriptor = fd
    size = Int(lseek(fd, 0, SEEK_END))
  }

  /// A page address reduced to what is safe to keep: `scheme://host`, or the bare scheme when
  /// there is no host. Path, query, fragment, port and credentials never reach a log.
  public static func origin(_ url: String) -> String {
    guard let parts = URLComponents(string: url), let scheme = parts.scheme else {
      return "invalid"
    }
    guard let host = parts.host, !host.isEmpty else { return scheme }
    return "\(scheme)://\(host)"
  }

  public func append(level: String, category: String, message: String) {
    lock.lock()
    defer { lock.unlock() }
    let text = String(message.prefix(Self.maxMessage)).replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(
        of: "\n", with: " ")
    let line = Array("\(timestamp.string(from: Date())) \(level) \(category) \(text)\n".utf8)
    followRotation()
    if size + line.count > cap { rotate() }
    if write(descriptor, line, line.count) > 0 { size += line.count }
  }

  private func rotate() {
    guard rename(path, path + ".1") == 0 else { return }
    // Keep the active pathname when reopening fails, so the next append can retry the rotation.
    if !reopen() { rename(path + ".1", path) }
  }

  /// Another process (the app, for the gateway) may have rotated the file, or it may have been
  /// deleted: the descriptor then names an old inode and lines would go to the rotated file.
  private func followRotation() {
    var onDisk = stat()
    var held = stat()
    guard fstat(descriptor, &held) == 0 else { return }
    if stat(path, &onDisk) != 0 || onDisk.st_ino != held.st_ino {
      _ = reopen()
    } else {
      size = Int(held.st_size)
    }
  }

  private func reopen() -> Bool {
    let fresh = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard fresh >= 0, dup2(fresh, descriptor) >= 0 else {
      if fresh >= 0 { close(fresh) }
      return false
    }
    close(fresh)
    size = Int(lseek(descriptor, 0, SEEK_END))
    return true
  }
}
