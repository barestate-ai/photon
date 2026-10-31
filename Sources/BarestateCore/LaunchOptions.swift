import Foundation

/// Everything the app keeps on disk lives under one directory.
public struct DataDir: Equatable, Sendable {
  public let root: String
  public var profile: String { root + "/profile" }
  public var sqlite: String { root + "/barestate.sqlite" }
  public var settings: String { root + "/settings.json" }
  public var socket: String { root + "/app.sock" }
  public var pid: String { root + "/app.pid" }
  public var tmp: String { root + "/tmp" }
  public var logs: String { root + "/logs" }
  public var spend: String { root + "/spend.json" }
  public var pairing: String { root + "/pairing.json" }
}

public struct LaunchOptions: Equatable, Sendable {
  public enum Failure: Error, Equatable {
    case missingValue(String)
    case socketPathTooLong(String)
  }

  public let dataDir: DataDir
  public let testHooks: Bool
  public let url: String?

  /// sockaddr_un.sun_path holds 104 bytes on macOS, including the terminating NUL.
  private static let maxSocketPath = 103

  /// Arguments the app does not own (macOS and Chromium add their own) are ignored.
  public static func parse(_ args: [String], home: String) throws -> LaunchOptions {
    var dataDir = home + "/Library/Application Support/Barestate/browser"
    var testHooks = false
    var url: String?
    var index = 0

    func value(of flag: String) throws -> String {
      index += 1
      guard index < args.count else { throw Failure.missingValue(flag) }
      return args[index]
    }

    while index < args.count {
      let arg = args[index]
      if arg == "--test-hooks" {
        testHooks = true
      } else if arg == "--data-dir" {
        dataDir = try value(of: arg)
      } else if arg.hasPrefix("--data-dir=") {
        dataDir = String(arg.dropFirst("--data-dir=".count))
      } else if arg == "--url" {
        url = try value(of: arg)
      } else if arg.hasPrefix("--url=") {
        url = String(arg.dropFirst("--url=".count))
      }
      index += 1
    }

    let root = URL(fileURLWithPath: dataDir).standardizedFileURL.path
    let layout = DataDir(root: root)
    guard layout.socket.utf8.count <= maxSocketPath else {
      throw Failure.socketPathTooLong(layout.socket)
    }
    return LaunchOptions(dataDir: layout, testHooks: testHooks, url: url)
  }
}
