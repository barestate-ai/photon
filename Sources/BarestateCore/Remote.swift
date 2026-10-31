import Foundation

/// The public side of pairing: where a phone reaches Photon and what its QR code says.
public enum Remote {
  /// The only Funnel port Photon serves (architecture §8).
  public static let funnelPort = 10000

  /// `Self.DNSName` from `tailscale status --json`, without the trailing dot.
  public static func host(fromTailscaleStatus json: Data) -> String? {
    struct Status: Decodable {
      struct Node: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "DNSName" }
      }
      let node: Node?
      enum CodingKeys: String, CodingKey { case node = "Self" }
    }
    guard let name = (try? JSONDecoder().decode(Status.self, from: json))?.node?.name else {
      return nil
    }
    let host = name.hasSuffix(".") ? String(name.dropLast()) : name
    return host.isEmpty ? nil : host
  }

  /// The only two `tailscale` forms Photon runs that change anything: they add and remove the
  /// `/barestate` handler on one Funnel port, and no other handler is named (architecture §8).
  public static func funnelMount(gatewayPort: Int) -> [String] {
    [
      "funnel", "--bg", "--https=\(funnelPort)", "--set-path=/barestate",
      "http://127.0.0.1:\(gatewayPort)",
    ]
  }

  public static let funnelUnmount = [
    "funnel", "--https=\(funnelPort)", "--set-path=/barestate", "off",
  ]

  private static let tailscaleApps = [
    "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  ]

  /// `BARESTATE_TAILSCALE` names a stand-in binary for tests.
  public static var tailscaleBinary: String? {
    ProcessInfo.processInfo.environment["BARESTATE_TAILSCALE"]
      ?? tailscaleApps.first(where: FileManager.default.isExecutableFile(atPath:))
  }

  /// Runs `tailscale` with `arguments`; true when it exits 0. A command that waits for a person
  /// (Funnel not yet allowed for this node) is cut off after `timeout` seconds.
  public static func runTailscale(_ arguments: [String], timeout: TimeInterval = 20) -> Bool {
    guard let binary = tailscaleBinary else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    guard (try? process.run()) != nil else { return false }
    if ended.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      return false
    }
    return process.terminationStatus == 0
  }

  /// The token travels in the fragment, which a browser never sends to the server.
  public static func pairingURL(host: String, token: String) -> String {
    "https://\(host):\(funnelPort)/barestate/#t=\(token)"
  }
}
