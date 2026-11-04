import BarestateCore
import Foundation

@MainActor
extension AppController {
  func modelEnvFile(_ environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String?
  {
    try? String(contentsOfFile: environment["BARESTATE_ENV_FILE"] ?? ".env", encoding: .utf8)
  }

  /// Under test hooks the Keychain is read only for a live run, so a test run never spends.
  private func modelKeychain(_ environment: [String: String]) -> @Sendable () -> String? {
    if testHooks && environment["BARESTATE_LIVE_META"] != "1" { return { nil } }
    return ModelKey.readKeychain
  }

  /// The Barestate Muse device token: the Keychain in normal use, a 0600 data-dir file under
  /// test hooks, so a test never touches the Keychain (D74).
  var museTokenStore: BarestateMuse.TokenStore {
    BarestateMuse.TokenStore(file: testHooks ? dataDir.deviceToken : nil)
  }

  /// Settings: this Mac holds a Barestate Muse device token (D74).
  var barestateMuseConnected: Bool { museTokenStore.read() != nil }

  /// Settings: the user holds a key of their own, so Barestate Muse is not offered. The offline
  /// simulation is about the network, not the key, so it does not count here.
  var ownModelKey: Bool {
    let environment = ProcessInfo.processInfo.environment
    let envFile = modelEnvFile(environment)
    // Baseten first, like the route in ModelClient: it short-circuits before a Keychain read.
    return ModelKey.resolve(
      variable: "BASETEN_API_KEY", environment: environment, envFile: envFile) != nil
      || ModelKey.resolve(
        environment: environment, envFile: envFile, keychain: modelKeychain(environment)) != nil
  }

  /// Built per call so the environment, `.env` and `test.modelOffline` are read fresh.
  func modelClient(
    timeout: TimeInterval = 60, onFailure: @escaping @Sendable (ModelError) -> Void = { _ in }
  ) -> ModelClient {
    var environment = ProcessInfo.processInfo.environment
    let keychain = modelKeychain(environment)
    let tokenStore = museTokenStore
    var transport = liveModelTransport
    if modelOffline {
      // The outage is simulated at the network, so it reads the same with or without a key.
      environment["MODEL_API_KEY"] = "offline"
      transport = { _, _ in throw URLError(.notConnectedToInternet) }
    }
    return ModelClient(
      environment: environment, envFile: modelEnvFile(environment),
      keychain: keychain, deviceToken: { tokenStore.read() }, ledger: spendLedger,
      transport: transport,
      timeout: timeout, log: { Log.info(.runs, $0) }, onFailure: onFailure)
  }

  /// Connect this Mac to Barestate Muse with an invite code (D74): nil on success, else the one
  /// line Settings shows. The code crosses the wire once and is never logged.
  func connectBarestateMuse(inviteCode: String) async -> String? {
    let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    do {
      let token = try await BarestateMuse.register(
        inviteCode: inviteCode, deviceName: name,
        environment: ProcessInfo.processInfo.environment)
      try museTokenStore.store(token)
      Log.info(.runs, "barestate muse connected")
      // A connect after an outage clears the latch through the same probe Retry uses.
      if modelLatched { _ = await retryMuse() }
      return nil
    } catch let error as BarestateMuse.ConnectError {
      Log.info(.runs, "barestate muse connect failed: \(error.logName)")
      return error.description
    } catch {
      Log.error(.runs, "barestate muse token store failed: \(Log.describe(error))")
      return BarestateMuse.ConnectError.storeFailed.description
    }
  }

  func disconnectBarestateMuse() {
    museTokenStore.remove()
    Log.info(.runs, "barestate muse disconnected")
  }

  /// A client for one run's calls (the loop, grounding, acknowledgement and verification alike):
  /// it refuses once the run has ended or reached its cap. Only the run's own loop call
  /// (`latches`) latches Muse unavailable when it meets an outage; a side call that fails says
  /// little about Muse, and the loop's next call finds out. `retrying` is the loop's first try,
  /// whose 5xx is tried once more before it counts.
  func modelClient(
    session: String, timeout: TimeInterval = 60, latches: Bool = false, retrying: Bool = false
  ) -> ModelClient {
    // A failure the test override simulated stays simulated if it is lifted before the failure lands.
    let simulated = modelOffline
    return modelClient(timeout: timeout) { [weak self] error in
      guard latches, !simulated, error.isOutage, !(retrying && error.isTransient) else { return }
      Task { @MainActor in self?.latchMuse(error) }
    }
    .labelled(session) { [weak self] in await self?.runs.refusal(session) }
  }

  /// Why Start task cannot reach Muse, if it cannot. `test.modelOffline` stands for an outage.
  var museOutage: MuseOutage? {
    if modelOffline { return .unreachable }
    return MuseAvailability.cause(
      hasKey: modelClient().hasKey, pathSatisfied: network.satisfied, latched: modelLatched)
  }

  private func latchMuse(_ error: ModelError) {
    guard !modelLatched else { return }
    modelLatched = true
    Log.info(.runs, "muse unavailable error=\(error.code)")
    settingsWindow?.refresh()
  }

  /// Retry: nil when the key, the network path and the provider's base URL all answer, which
  /// clears the latch; otherwise what it found. The probe carries no key and no tokens, and any
  /// HTTP status is an answer.
  func retryMuse() async -> MuseOutage? {
    let client = modelClient()
    var cause = await MuseAvailability.retry(
      hasKey: client.hasKey, pathSatisfied: network.satisfied,
      probe: { await Self.reachable(client.probeURL) })
    Log.info(.runs, "muse retry cause=\(cause.map { "\($0)" } ?? "none")")
    if cause == nil {
      // The key or the path may have gone while the probe was out.
      cause = MuseAvailability.cause(
        hasKey: modelClient().hasKey, pathSatisfied: network.satisfied, latched: false)
    }
    guard cause == nil else { return cause }
    modelLatched = false
    settingsWindow?.refresh()
    return nil
  }

  private static func reachable(_ url: URL?) async -> Bool {
    guard let url else { return false }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "HEAD"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      _ = try await URLSession.shared.data(for: request, delegate: NoRedirect())
      return true
    } catch {
      Log.info(.runs, "muse probe failed \(Log.describe(error))")
      return false
    }
  }
}

/// The probe asks whether the base URL answers, not where it points.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection: HTTPURLResponse,
    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
