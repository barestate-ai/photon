import BarestateCore
import Foundation
import Testing

struct SpendLedgerTests {
  private func tempPath() -> String {
    NSTemporaryDirectory() + "spend-\(UUID().uuidString).json"
  }

  private func write(_ text: String, to path: String) {
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
  }

  private func read(_ path: String) -> JSON {
    JSON.parse(FileManager.default.contents(atPath: path) ?? Data()) ?? .null
  }

  private let seed = """
    {"cap_usd":40,"per_run_cap_usd":3,"total_usd":0.5,"entries":[
    {"ts":"2026-10-27T22:48:42Z","source":"old","model":"muse-spark-1.3","endpoint":"/responses",
     "input_tokens":1,"output_tokens":2,"cached_tokens":0,"usd":0.5,"pricing_basis":"x"}]}
    """

  @Test func anEntryUsesTheExistingSchemaAndKeepsHistory() throws {
    let path = tempPath()
    write(seed, to: path)
    let usd = try SpendLedger(path: path).record(
      source: "test", model: "muse-spark-1.3", endpoint: "/responses",
      usage: ModelUsage(input: 564, output: 93, cached: 113))
    #expect(usd == 0.000976)
    let file = read(path)
    #expect(file["total_usd"]?.number == 0.500976)
    #expect(file["cap_usd"]?.number == 40)
    let entries = try #require(file["entries"]?.array)
    #expect(entries.count == 2)
    #expect(entries[0]["source"]?.string == "old")
    let entry = entries[1]
    #expect(
      Set(entry.object!.keys) == [
        "ts", "source", "model", "endpoint", "input_tokens", "output_tokens", "cached_tokens",
        "usd", "pricing_basis",
      ])
    #expect(entry["source"]?.string == "test")
    #expect(entry["input_tokens"]?.int == 564)
    #expect(entry["cached_tokens"]?.int == 113)
    #expect(entry["usd"]?.number == 0.000976)
  }

  @Test func pricesFollowTheTable() {
    let usage = ModelUsage(input: 1_000_000, output: 1_000_000, cached: 0)
    #expect(SpendLedger.price(model: "muse-spark-1.3", usage: usage).usd == 5.5)
    #expect(SpendLedger.price(model: "muse-spark-1.3-contributor", usage: usage).usd == 0.3)
    #expect(SpendLedger.price(model: "muse-wonder-1.0", usage: usage).usd == 24)
    let cached = ModelUsage(input: 1_000_000, output: 0, cached: 1_000_000)
    #expect(SpendLedger.price(model: "muse-spark-1.3", usage: cached).usd == 0.15)
  }

  @Test func anUnlistedModelIsPricedAtTheHighestRate() {
    let usage = ModelUsage(input: 1_000_000, output: 0, cached: 0)
    #expect(SpendLedger.price(model: "something-new", usage: usage).usd == 4)
  }

  @Test func theCapRefusesAtOrAboveForty() throws {
    let path = tempPath()
    let ledger = SpendLedger(path: path)
    write(#"{"total_usd":39.99,"entries":[]}"#, to: path)
    try ledger.ensureUnderCap()
    write(#"{"total_usd":40,"entries":[]}"#, to: path)
    #expect(throws: ModelError.capReached(total: 40)) { try ledger.ensureUnderCap() }
    write(#"{"total_usd":41.5,"entries":[]}"#, to: path)
    #expect(throws: ModelError.capReached(total: 41.5)) { try ledger.ensureUnderCap() }
  }

  @Test func aMissingFileIsCreatedWithTheDefaults() throws {
    let path = tempPath()
    try SpendLedger(path: path).ensureUnderCap()
    _ = try SpendLedger(path: path).record(
      source: "s", model: "muse-spark-1.3", endpoint: "/responses",
      usage: ModelUsage(input: 10, output: 10, cached: 0))
    let file = read(path)
    #expect(file["cap_usd"]?.number == 40)
    #expect(file["per_run_cap_usd"]?.number == 3)
    #expect(file["entries"]?.array?.count == 1)
  }

  @Test func aFileThatIsNotALedgerIsRefusedAndLeftAlone() {
    let path = tempPath()
    write("not json", to: path)
    let ledger = SpendLedger(path: path)
    #expect(throws: (any Error).self) { try ledger.ensureUnderCap() }
    #expect(throws: (any Error).self) {
      try ledger.record(
        source: "s", model: "m", endpoint: "/responses",
        usage: ModelUsage(input: 1, output: 1, cached: 0))
    }
    #expect(try! String(contentsOfFile: path, encoding: .utf8) == "not json")
  }

  @Test func aCorruptOrEmptyLedgerFailsClosed() throws {
    let path = tempPath()
    let ledger = SpendLedger(path: path)
    for text in [
      "", "{}", #"{"total_usd":-1,"entries":[]}"#, #"{"total_usd":"9","entries":[]}"#,
      #"{"total_usd":1}"#,
    ] {
      write(text, to: path)
      #expect(throws: ModelError.self) { try ledger.ensureUnderCap() }
    }
  }

  @Test func twoWritersOnOneFileLoseNoEntry() throws {
    let path = tempPath()
    let ledgers = [SpendLedger(path: path), SpendLedger(path: path)]
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      _ = try? ledgers[index % 2].record(
        source: "s\(index)", model: "muse-spark-1.3", endpoint: "/responses",
        usage: ModelUsage(input: 1, output: 1, cached: 0))
    }
    #expect(read(path)["entries"]?.array?.count == 20)
  }
}
