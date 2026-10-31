import BarestateCore
import Foundation

@MainActor
extension AppController {
  func modelEnvFile(_ environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String?
  {
    try? String(contentsOfFile: environment["BARESTATE_ENV_FILE"] ?? ".env", encoding: .utf8)
  }

  /// Built per call so the environment, `.env` and `test.modelOffline` are read fresh.
  func modelClient(
    timeout: TimeInterval = 60, onFailure: @escaping @Sendable (ModelError) -> Void = { _ in }
  ) -> ModelClient {
    var environment = ProcessInfo.processInfo.environment
    // Under test hooks the Keychain is read only for a live run, so a test run never spends.
    var keychain: @Sendable () -> String? = ModelKey.readKeychain
    if testHooks && environment["BARESTATE_LIVE_META"] != "1" { keychain = { nil } }
    var transport = liveModelTransport
    if modelOffline {
      // The outage is simulated at the network, so it reads the same with or without a key.
      environment["MODEL_API_KEY"] = "offline"
      transport = { _, _ in throw URLError(.notConnectedToInternet) }
    }
    return ModelClient(
      environment: environment, envFile: modelEnvFile(environment),
      keychain: keychain, ledger: spendLedger, transport: transport,
      timeout: timeout, log: { Log.info(.runs, $0) }, onFailure: onFailure)
  }

  /// A client for one run's calls (the loop, grounding, acknowledgement and verification alike):
  /// it refuses once the run has ended or reached its cap, and an outage it meets latches Muse
  /// unavailable. `retrying` is the loop's first try, whose 5xx is tried once more before it
  /// counts.
  func modelClient(session: String, timeout: TimeInterval = 60, retrying: Bool = false)
    -> ModelClient
  {
    // A failure the test override simulated stays simulated if it is lifted before the failure lands.
    let simulated = modelOffline
    return modelClient(timeout: timeout) { [weak self] error in
      guard !simulated, error.isOutage, !(retrying && error.isTransient) else { return }
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

  /// Retry: true when the key, the network path and the provider's base URL all answer, which
  /// clears the latch. The probe carries no key and no tokens, and any HTTP status is an answer.
  func retryMuse() async -> Bool {
    let client = modelClient()
    let cause = await MuseAvailability.retry(
      hasKey: client.hasKey, pathSatisfied: network.satisfied,
      probe: { await Self.reachable(client.probeURL) })
    Log.info(.runs, "muse retry cause=\(cause.map { "\($0)" } ?? "none")")
    // The key or the path may have gone while the probe was out.
    guard cause == nil, modelClient().hasKey, network.satisfied else { return false }
    modelLatched = false
    settingsWindow?.refresh()
    return true
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
