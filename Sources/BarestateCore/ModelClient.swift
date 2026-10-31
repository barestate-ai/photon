import Foundation

/// Routing (D3): `muse-spark-1.3` unless `BARESTATE_MODEL` says otherwise, and never wonder for
/// the computer tool.
public enum ModelRouter {
  public static let standard = "muse-spark-1.3"

  public static func model(computer: Bool, override: String?) -> String {
    let wanted = override?.trimmingCharacters(in: .whitespaces) ?? ""
    if wanted.isEmpty || (computer && wanted.hasPrefix("muse-wonder")) { return standard }
    return wanted
  }
}

/// One entry point for every model call: cap check, provider choice, request, spend entry.
/// `BASETEN_API_KEY` selects the Baseten chat adapter; otherwise the Meta Responses provider.
public struct ModelClient: Sendable {
  static let basetenURL = "https://inference.baseten.co/v1"
  static let metaURL = "https://api.meta.ai/v1"
  static let basetenModel = "meta-models/muse-spark-open"

  let environment: [String: String]
  let envFile: String?
  let keychain: @Sendable () -> String?
  let ledger: SpendLedger
  let transport: ModelTransport
  let timeout: TimeInterval
  let log: @Sendable (String) -> Void
  let onFailure: @Sendable (ModelError) -> Void
  private var runLabel = ""
  private var gate: (@Sendable () async -> ModelError?)?

  public init(
    environment: [String: String], envFile: String?,
    keychain: @escaping @Sendable () -> String? = { nil }, ledger: SpendLedger,
    transport: @escaping ModelTransport = liveModelTransport, timeout: TimeInterval = 60,
    log: @escaping @Sendable (String) -> Void = { _ in },
    onFailure: @escaping @Sendable (ModelError) -> Void = { _ in }
  ) {
    self.environment = environment
    self.envFile = envFile
    self.keychain = keychain
    self.ledger = ledger
    self.transport = transport
    self.timeout = timeout
    self.log = log
    self.onFailure = onFailure
  }

  private var baseten: ModelKey.Found? {
    ModelKey.resolve(variable: "BASETEN_API_KEY", environment: environment, envFile: envFile)
  }

  /// A key for the provider `call` would use is there. Nothing is sent and the value is not read
  /// out.
  public var hasKey: Bool {
    baseten != nil
      || ModelKey.resolve(environment: environment, envFile: envFile, keychain: keychain) != nil
  }

  /// The base URL of the provider `call` would use; a reachability probe goes here.
  public var probeURL: URL? {
    URL(
      string: baseten != nil
        ? environment["BARESTATE_BASETEN_URL"] ?? Self.basetenURL
        : environment["BARESTATE_META_URL"] ?? Self.metaURL)
  }

  /// The same client with every spend entry's source prefixed `<session>:`, so a run's cost can
  /// be summed from the ledger. `gate` is asked before each request and may refuse it: the run
  /// it belongs to has ended or is over its cap, whichever call of the run this is.
  public func labelled(_ session: String, gate: (@Sendable () async -> ModelError?)? = nil)
    -> ModelClient
  {
    var copy = self
    copy.runLabel = session + ":"
    copy.gate = gate
    return copy
  }

  /// Throws before any network request when the cap is reached, the key is missing or the
  /// request cannot be sent to the chosen provider. A failed call writes no spend entry.
  public func call(_ request: ModelRequest, source: String) async throws -> ModelResponse {
    let source = runLabel + source
    do {
      if let refusal = await gate?() { throw refusal }
      try ledger.ensureUnderCap()
      let (provider, name) = try select(request)
      var response = try await provider.respond(request)
      response.usd = try ledger.record(
        source: source, model: response.model, endpoint: response.endpoint, usage: response.usage)
      log(
        "model call provider=\(name) model=\(response.model) endpoint=\(response.endpoint) "
          + "request=\(response.requestId ?? "-") usd=\(response.usd) source=\(source)")
      return response
    } catch let error as ModelError {
      log("model call failed source=\(source) error=\(error.code)")
      onFailure(error)
      throw error
    }
  }

  private func select(_ request: ModelRequest) throws -> (any ModelProvider, String) {
    let http = ModelHTTP(transport: transport, timeout: timeout)
    if let baseten {
      guard let base = probeURL else {
        throw ModelError.refused("BARESTATE_BASETEN_URL is not a URL")
      }
      let provider = BasetenChatProvider(
        model: environment["BARESTATE_BASETEN_MODEL"] ?? Self.basetenModel, key: baseten.value,
        http: http, baseURL: base)
      return (provider, "baseten")
    }
    guard
      let meta = ModelKey.resolve(environment: environment, envFile: envFile, keychain: keychain)
    else { throw ModelError.noKey }
    let model = ModelRouter.model(
      computer: request.computer, override: environment["BARESTATE_MODEL"])
    guard let base = probeURL else { throw ModelError.refused("BARESTATE_META_URL is not a URL") }
    return (MetaResponsesProvider(model: model, key: meta.value, http: http, baseURL: base), "meta")
  }
}
