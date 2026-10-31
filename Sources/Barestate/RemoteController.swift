import BarestateCore
import Foundation

/// Remote (architecture §8): the gateway process, the pairing list and the text of the pairing
/// QR code. Remote is off at every launch; nothing about it is saved but the pairings.
@MainActor
final class RemoteController {
  static let gatewayPort = 47820
  /// Funnel commands run one at a time and in order, so an unmount queued by a quick disable
  /// always follows the mount it undoes.
  private nonisolated static let funnelQueue = DispatchQueue(label: "barestate.funnel")
  /// Hermetic test runs set this to `off`: they must never change the Mac's Funnel.
  private nonisolated static var funnelEnabled: Bool {
    ProcessInfo.processInfo.environment["BARESTATE_FUNNEL"] != "off"
  }

  private unowned let app: AppController
  private var gateway: Process?
  private var host: String?
  private(set) var starting = false
  /// Counts enables and disables, so a host lookup that outlives its request is dropped.
  private var attempt = 0
  /// Whether this run may have added the `/barestate` Funnel handler.
  private var mounted = false
  /// Why Remote is not on, for Settings.
  private(set) var problem: String?

  init(app: AppController) { self.app = app }

  var isOn: Bool { gateway != nil && host != nil }
  var isRequested: Bool { starting || isOn }

  var statusText: String {
    if let problem { return problem }
    if starting { return "Starting…" }
    return isOn ? "On. Pair a phone to connect it." : "Off. Turn on to pair a phone."
  }

  private var store: PairingStore { PairingStore(path: app.dataDir.pairing) }

  /// Each pairing with when its device last came, newest pairing last.
  var devices: [(pairing: Pairing, lastSeen: String?)] {
    let seen = store.lastSeen()
    return store.list().map { ($0, seen[$0.hash]) }
  }

  func enable() {
    guard !isRequested else { return }
    starting = true
    problem = nil
    attempt += 1
    let mine = attempt
    changed()
    Task {
      let found = await Self.lookupHost()
      guard attempt == mine else { return }
      guard let found else {
        starting = false
        Log.error(.remote, "enable failed: no tailscale host")
        problem = "Tailscale is not available. Remote needs it."
        return changed()
      }
      if Self.funnelEnabled {
        mounted = true
        let mounting = await Self.tailscale(Remote.funnelMount(gatewayPort: Self.gatewayPort))
        // A disable that came meanwhile has queued the unmount behind this mount.
        guard attempt == mine else { return }
        Log.info(.remote, "funnel mount ok=\(mounting)")
        guard mounting else {
          starting = false
          problem = "Tailscale Funnel could not start. Is Funnel allowed for this Mac?"
          unmount()
          return changed()
        }
      }
      starting = false
      launch(host: found)
      changed()
    }
  }

  /// `wait`: quitting, where the unmount has to finish before the process exits.
  func disable(wait: Bool = false) {
    // Also drains an unmount a quick disable queued just before the quit.
    defer { if wait { Self.funnelQueue.sync {} } }
    guard isRequested || problem != nil || mounted else { return }
    let stopping = gateway
    attempt += 1
    starting = false
    gateway = nil
    host = nil
    problem = nil
    stopping?.terminate()
    unmount()
    Log.info(.remote, "disabled")
    changed()
  }

  /// Queued at once, so nothing that runs after this call can overtake it.
  private func unmount() {
    guard mounted else { return }
    mounted = false
    Self.funnelQueue.async {
      let unmounted = Remote.runTailscale(Remote.funnelUnmount)
      Log.info(.remote, "funnel unmount ok=\(unmounted)")
    }
  }

  /// A new pairing and its token, which the caller alone ever holds.
  func pair(label: String? = nil) -> String? {
    do {
      let token = try store.mint(label: label ?? "Phone \(store.list().count + 1)")
      Log.info(.remote, "pair hash=\(PairingStore.hash(token).prefix(8))")
      changed()
      return token
    } catch {
      Log.error(.remote, "pair failed: \(Log.describe(error))")
      problem = "Could not save the pairing."
      changed()
      return nil
    }
  }

  func pairingURL(_ token: String) -> String? {
    host.map { Remote.pairingURL(host: $0, token: token) }
  }

  func revoke(hash: String) {
    do {
      try store.revoke(hash: hash)
      Log.info(.remote, "revoke hash=\(hash.prefix(8))")
    } catch {
      Log.error(.remote, "revoke failed: \(Log.describe(error))")
      problem = "Could not revoke the pairing."
    }
    changed()
  }

  private func launch(host found: String) {
    let process = Process()
    process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("barestate-gateway")
    process.arguments = [
      "--port", "\(Self.gatewayPort)", "--socket", app.dataDir.socket,
      "--public-host", "\(found):\(Remote.funnelPort)", "--parent", "\(getpid())",
      "--phone-dir", (Bundle.main.resourcePath ?? "") + "/phone",
    ]
    // The gateway outlives a crashed app, so it removes the handler this run mounted.
    if mounted { process.arguments?.append("--unmount-funnel-on-exit") }
    process.standardInput = FileHandle.nullDevice
    process.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      Task { @MainActor in self?.exited(process, status: status) }
    }
    do {
      try process.run()
    } catch {
      Log.error(.remote, "gateway launch failed: \(Log.describe(error))")
      problem = "Remote could not start."
      unmount()
      return
    }
    gateway = process
    host = found
    Log.info(.remote, "enabled gateway pid=\(process.processIdentifier) port=\(Self.gatewayPort)")
  }

  /// A gateway that stops without being asked (its port taken, a crash) turns Remote off.
  private func exited(_ process: Process, status: Int32) {
    guard gateway === process else { return }
    Log.error(.remote, "gateway exited status=\(status)")
    gateway = nil
    host = nil
    problem = "Remote stopped. Is port \(Self.gatewayPort) in use?"
    unmount()
    changed()
  }

  private func changed() { app.settingsWindow?.refresh() }

  /// Runs `tailscale` with `arguments` on the funnel queue; true when it exits 0.
  private nonisolated static func tailscale(_ arguments: [String]) async -> Bool {
    await withCheckedContinuation { done in
      funnelQueue.async { done.resume(returning: Remote.runTailscale(arguments)) }
    }
  }

  /// `tailscale status --json` is read-only; it names this Mac's public host.
  private nonisolated static func lookupHost() async -> String? {
    guard let binary = Remote.tailscaleBinary else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["status", "--json"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Remote.host(fromTailscaleStatus: data)
  }
}
