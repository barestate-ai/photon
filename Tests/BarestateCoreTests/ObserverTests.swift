import BarestateCore
import Foundation
import Testing

/// Answers each DevTools method from the captured fixture and records what was asked.
private final class FakeTransport: CDPTransport, @unchecked Sendable {
  let events = AsyncStream<CDPEvent>.makeStream().stream
  private let lock = NSLock()
  private var methods: [String] = []

  var asked: [String] { lock.withLock { methods } }

  func send(_ method: String, _ params: JSON) async throws -> JSON {
    lock.withLock { methods.append(method) }
    let url = Bundle.module.url(
      forResource: "observe-fixture", withExtension: "json", subdirectory: "Fixtures")!
    let captured = JSON.parse(try Data(contentsOf: url))!
    switch method {
    case "DOMSnapshot.captureSnapshot": return captured["snapshot"]!
    case "Accessibility.getFullAXTree": return captured["ax"]!
    case "Page.getLayoutMetrics": return captured["metrics"]!
    case "Page.getFrameTree": return captured["frametree"]!
    case "Runtime.evaluate": return captured["dpr"]!
    default: throw CDPError.remote(code: -32601, message: method)
    }
  }
}

/// A page that navigates just after a snapshot is taken: the snapshot describes the document
/// that is going away, every read after it describes the new one. Each document's elements sit
/// 10 000 px further right than the previous one's, so an element says which document it came from.
private final class NavigatingTransport: CDPTransport, @unchecked Sendable {
  static let spacing = 10_000.0

  let events = AsyncStream<CDPEvent>.makeStream().stream
  private let lock = NSLock()
  private let navigatesOnEverySnapshot: Bool
  private var generation = 0
  private(set) var snapshots = 0

  init(navigatesOnEverySnapshot: Bool = false) {
    self.navigatesOnEverySnapshot = navigatesOnEverySnapshot
  }

  var currentGeneration: Int { lock.withLock { generation } }

  func send(_ method: String, _ params: JSON) async throws -> JSON {
    let url = Bundle.module.url(
      forResource: "observe-fixture", withExtension: "json", subdirectory: "Fixtures")!
    let captured = JSON.parse(try Data(contentsOf: url))!
    switch method {
    case "DOMSnapshot.captureSnapshot":
      let taken = lock.withLock { () -> Int in
        snapshots += 1
        let taken = generation
        if navigatesOnEverySnapshot || snapshots == 1 { generation += 1 }
        return taken
      }
      return Self.titled(
        Self.shifted(captured["snapshot"]!, by: Double(taken) * Self.spacing),
        "Document \(taken)")
    case "Accessibility.getFullAXTree": return captured["ax"]!
    case "Page.getLayoutMetrics": return captured["metrics"]!
    case "Page.getFrameTree":
      var fields = captured["frametree"]!["frameTree"]!["frame"]!.object!
      fields["loaderId"] = .string("L\(currentGeneration)")
      return ["frameTree": ["frame": .object(fields)]]
    case "Runtime.evaluate": return captured["dpr"]!
    default: throw CDPError.remote(code: -32601, message: method)
    }
  }

  private static func titled(_ snapshot: JSON, _ title: String) -> JSON {
    guard case .object(var root) = snapshot, case .array(var strings)? = root["strings"],
      let index = root["documents"]?[0]?["title"]?.int
    else { return snapshot }
    strings[index] = .string(title)
    root["strings"] = .array(strings)
    return .object(root)
  }

  private static func shifted(_ snapshot: JSON, by dx: Double) -> JSON {
    guard case .object(var root) = snapshot, case .array(var documents)? = root["documents"],
      case .object(var document)? = documents.first, case .object(var layout)? = document["layout"],
      case .array(let boxes)? = layout["bounds"]
    else { return snapshot }
    layout["bounds"] = .array(
      boxes.map { box in
        guard case .array(var values) = box, case .number(let x)? = values.first else { return box }
        values[0] = .number(x + dx)
        return .array(values)
      })
    document["layout"] = .object(layout)
    documents[0] = .object(document)
    root["documents"] = .array(documents)
    return .object(root)
  }
}

struct ObserverTests {
  @Test func anObservationTakenAcrossANavigationDescribesOneDocument() async throws {
    let transport = NavigatingTransport()
    let observation = try await Observer.observe(
      transport: transport, id: "o1", tabId: "t1", epoch: 0)
    let generation = transport.currentGeneration
    #expect(generation == 1)
    #expect(observation.documentKey.hasSuffix(":L\(generation)"))
    #expect(observation.title == "Document \(generation)")
    #expect(!observation.elements.isEmpty)
    for element in observation.elements where element.bounds.w > 0 {
      #expect(Int(element.bounds.x / NavigatingTransport.spacing) == generation)
    }
    #expect(transport.snapshots == 2)
  }

  @Test func aPageThatNeverSettlesIsReportedNotGuessed() async {
    let transport = NavigatingTransport(navigatesOnEverySnapshot: true)
    await #expect(throws: ObservationError.unstable) {
      try await Observer.observe(transport: transport, id: "o1", tabId: "t1", epoch: 0)
    }
    #expect(transport.snapshots == Observer.attempts)
  }

  @Test func observeIssuesTheFiveReadsAndReducesThem() async throws {
    let transport = FakeTransport()
    let observation = try await Observer.observe(
      transport: transport, id: "o7", tabId: "t2", epoch: 5)
    #expect(
      Set(transport.asked) == [
        "DOMSnapshot.captureSnapshot", "Accessibility.getFullAXTree", "Page.getLayoutMetrics",
        "Page.getFrameTree", "Runtime.evaluate",
      ])
    #expect(observation.id == "o7")
    #expect(observation.title == "Observe fixture")
    #expect(observation.elements.contains { $0.name == "Go" && $0.interactive })
  }
}
