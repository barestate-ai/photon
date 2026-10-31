import Foundation

/// The spend log (`BARESTATE_SPEND_LOG`): `cap_usd`, `per_run_cap_usd`, `total_usd`, `entries`.
/// Entries are only ever appended; a file that does not parse is refused, never replaced.
public final class SpendLedger: @unchecked Sendable {
  public static let capUSD = 40.0

  struct Rate {
    let input: Double
    let cached: Double
    let output: Double
    let basis: String
  }

  private static let docs = "https://dev.meta.ai/docs/pricing-rate-limits (per-token list price)"
  private static let spark = Rate(input: 1.25, cached: 0.15, output: 4.25, basis: docs)
  private static let contributor = Rate(input: 0.10, cached: 0.002, output: 0.20, basis: docs)
  /// USD per million tokens.
  private static let rates: [String: Rate] = [
    "muse-spark-1.3": spark, "muse-spark-1.2": spark, "muse-spark-1.1": spark,
    "muse-spark-1.3-contributor": contributor, "muse-spark-1.2-contributor": contributor,
    "muse-wonder-1.0": Rate(input: 4.00, cached: 0.20, output: 20.00, basis: docs),
    "meta-models/muse-spark-open": Rate(
      input: 1.25, cached: 0.15, output: 4.25,
      basis: "Baseten price not published; priced as muse-spark-1.3"),
  ]
  private static let unlisted = Rate(
    input: 4.00, cached: 0.20, output: 20.00, basis: "unlisted model, priced at the highest rate")

  private let path: String
  private let lock = NSLock()

  public init(path: String) { self.path = path }

  /// `input` includes the cached tokens, as the API reports them.
  public static func price(model: String, usage: ModelUsage) -> (usd: Double, basis: String) {
    let rate = rates[model] ?? unlisted
    let raw =
      Double(usage.input - usage.cached) * rate.input + Double(usage.cached) * rate.cached
      + Double(usage.output) * rate.output
    return (micro(raw / 1_000_000), rate.basis)
  }

  public func ensureUnderCap() throws {
    let total = try lock.withLock { try load()["total_usd"]?.number ?? 0 }
    if total >= Self.capUSD { throw ModelError.capReached(total: total) }
  }

  /// What the calls labelled `<session>:…` have cost so far.
  public func spent(session: String) throws -> Double {
    let entries = try lock.withLock { try load()["entries"]?.array ?? [] }
    let prefix = session + ":"
    let usd = entries.filter { $0["source"]?.string?.hasPrefix(prefix) == true }
      .reduce(0.0) { $0 + ($1["usd"]?.number ?? 0) }
    return Self.micro(usd)
  }

  /// Appends one entry and returns its cost.
  @discardableResult
  public func record(source: String, model: String, endpoint: String, usage: ModelUsage) throws
    -> Double
  {
    let (usd, basis) = Self.price(model: model, usage: usage)
    try exclusive {
      var fields = try load().object ?? [:]
      var entries = fields["entries"]?.array ?? []
      entries.append([
        "ts": .string(ISO8601DateFormatter().string(from: Date())), "source": .string(source),
        "model": .string(model), "endpoint": .string(endpoint),
        "input_tokens": .number(Double(usage.input)),
        "output_tokens": .number(Double(usage.output)),
        "cached_tokens": .number(Double(usage.cached)), "usd": .number(usd),
        "pricing_basis": .string(basis),
      ])
      fields["entries"] = .array(entries)
      fields["total_usd"] = .number(Self.micro((fields["total_usd"]?.number ?? 0) + usd))
      fields["cap_usd"] = fields["cap_usd"] ?? .number(Self.capUSD)
      fields["per_run_cap_usd"] = fields["per_run_cap_usd"] ?? 3
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      do {
        try encoder.encode(JSON.object(fields)).write(
          to: URL(fileURLWithPath: path), options: .atomic)
      } catch { throw ModelError.ledger("cannot write \(path)") }
    }
    return usd
  }

  /// The sidecar flock keeps a second process (the app and a live test share one log) from
  /// overwriting an append between our read and our rename.
  private func exclusive(_ body: () throws -> Void) throws {
    try lock.withLock {
      let descriptor = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw ModelError.ledger("cannot lock \(path)") }
      defer { close(descriptor) }
      flock(descriptor, LOCK_EX)
      try body()
    }
  }

  private static func micro(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }

  /// A missing file is an empty ledger. Anything else must be a ledger, or the cap would fail
  /// open on a corrupt or unreadable file.
  private func load() throws -> JSON {
    guard FileManager.default.fileExists(atPath: path) else { return .object([:]) }
    guard let data = FileManager.default.contents(atPath: path), let json = JSON.parse(data),
      let total = json["total_usd"]?.number, total.isFinite, total >= 0,
      json["entries"]?.array != nil
    else { throw ModelError.ledger("\(path) is not a ledger") }
    return json
  }
}
