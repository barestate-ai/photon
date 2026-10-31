import BarestateCore
import Darwin
import Foundation
import Testing

/// A fake Atom runtime (Fixtures/fake_atom.py) with a plan and a log of everything it saw.
private final class FakeRuntime: @unchecked Sendable {
  struct Entry {
    let t: Double
    let pid: Int
    let kind: String
    let text: String
  }

  let directory: URL
  let log: URL
  let launch: AtomClient.Launch

  init(plan: [String: Any] = [:]) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "atom-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    log = directory.appendingPathComponent("log.jsonl")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let planFile = directory.appendingPathComponent("plan.json")
    try JSONSerialization.data(withJSONObject: plan).write(to: planFile)
    let script = Bundle.module.url(
      forResource: "fake_atom", withExtension: "py", subdirectory: "Fixtures")!
    launch = AtomClient.Launch(
      executable: "/usr/bin/python3", arguments: [script.path],
      environment: ["FAKE_ATOM_PLAN": planFile.path, "FAKE_ATOM_LOG": log.path])
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  var entries: [Entry] {
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { return nil }
      return Entry(
        t: object["t"] as? Double ?? 0, pid: object["pid"] as? Int ?? 0,
        kind: object["kind"] as? String ?? "", text: object["text"] as? String ?? "")
    }
  }

  /// The ground requests the runtime received, by instruction.
  var received: [String] {
    entries.filter { $0.kind == "in" && $0.text.contains("\"ground\"") }.compactMap {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any],
        let params = object["params"] as? [String: Any]
      else { return nil }
      return params["instruction"] as? String
    }
  }

  var starts: [Int] { entries.filter { $0.kind == "start" }.map(\.pid) }

  func eventually(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
      guard Date() < deadline else { throw Failure(what: what) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  struct Failure: Error { let what: String }
}

private func alive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 }

private func client(
  _ runtime: FakeRuntime, timeout: Duration = .milliseconds(500)
) -> AtomClient {
  AtomClient(launch: runtime.launch, warmTimeout: timeout, coldTimeout: timeout)
}

struct AtomClientTests {
  @Test func normalizedPointsScaleByOneThousand() {
    let point = AtomPoint(x: 499, y: 430).css(width: 800, height: 600)
    #expect(abs(point.x - 399.2) < 1e-9 && abs(point.y - 258) < 1e-9)
    let corner = AtomPoint(x: 999, y: 999).css(width: 1000, height: 1000)
    #expect(corner.x == 999 && corner.y == 999)
  }

  @Test func aSuccessfulReplyIsTheNormalizedPoint() async throws {
    let runtime = try FakeRuntime()
    let atom = client(runtime)
    let reply = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p123")
    #expect(reply == .point(AtomPoint(x: 123, y: 124)))
    await atom.stop()
  }

  @Test func threeConcurrentCallsAreSentOneAtATimeAndEachCallerGetsItsOwnPoint() async throws {
    let runtime = try FakeRuntime(plan: ["default": ["delay": 0.15]])
    let atom = client(runtime, timeout: .seconds(5))
    async let first = atom.ground(imagePath: "/tmp/a.png", instruction: "p100")
    async let second = atom.ground(imagePath: "/tmp/a.png", instruction: "p200")
    async let third = atom.ground(imagePath: "/tmp/a.png", instruction: "p300")
    let replies = try await [first, second, third]
    #expect(
      replies == [
        .point(AtomPoint(x: 100, y: 101)), .point(AtomPoint(x: 200, y: 201)),
        .point(AtomPoint(x: 300, y: 301)),
      ])
    let traffic = runtime.entries.filter { $0.kind == "in" || $0.kind == "out" }.map(\.kind)
    #expect(traffic == ["in", "out", "in", "out", "in", "out"])
    await atom.stop()
  }

  @Test func garbageTruncatedAndNullIdLinesAreDroppedBeforeTheRealReply() async throws {
    let runtime = try FakeRuntime(plan: ["1:1": ["garbage": true]])
    let atom = client(runtime)
    let reply = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p123")
    #expect(reply == .point(AtomPoint(x: 123, y: 124)))
    await atom.stop()
  }

  @Test func aTimeoutKillsTheProcessRespawnsAndIgnoresALateReplyForTheOldRequest() async throws {
    let runtime = try FakeRuntime(plan: ["1:1": ["hang": true], "2:1": ["stale": "1"]])
    let atom = client(runtime, timeout: .milliseconds(400))
    await #expect(throws: AtomClient.Failure.timeout) {
      try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
    }
    let first = try #require(runtime.starts.first)
    #expect(!alive(first))
    try await runtime.eventually("a second process") { runtime.starts.count == 2 }
    let second = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p7")
    #expect(second == .point(AtomPoint(x: 7, y: 8)))
    #expect(Set(runtime.starts).count == 2)
    await atom.stop()
  }

  @Test func requestsQueuedPastTheirDeadlineAreNeverSentAndALaterOneIsServed() async throws {
    let runtime = try FakeRuntime(plan: ["1:1": ["delay": 0.5]])
    let atom = client(runtime, timeout: .seconds(5))
    let first = Task { try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1") }
    try await runtime.eventually("the first request") { runtime.received == ["p1"] }
    let soon = ContinuousClock.now + .milliseconds(100)
    let second = Task {
      try await atom.ground(imagePath: "/tmp/a.png", instruction: "p2", deadline: soon)
    }
    let third = Task {
      try await atom.ground(imagePath: "/tmp/a.png", instruction: "p3", deadline: soon)
    }
    let fourth = Task {
      try await atom.ground(
        imagePath: "/tmp/a.png", instruction: "p4", deadline: .now + .seconds(10))
    }
    #expect(try await first.value == .point(AtomPoint(x: 1, y: 2)))
    await #expect(throws: AtomClient.Failure.timeout) { try await second.value }
    await #expect(throws: AtomClient.Failure.timeout) { try await third.value }
    #expect(try await fourth.value == .point(AtomPoint(x: 4, y: 5)))
    #expect(runtime.received == ["p1", "p4"])
    await atom.stop()
  }

  @Test func aDeadlineThatHasAlreadyPassedSendsNothing() async throws {
    let runtime = try FakeRuntime()
    let atom = client(runtime)
    await #expect(throws: AtomClient.Failure.timeout) {
      try await atom.ground(
        imagePath: "/tmp/a.png", instruction: "p1", deadline: .now - .seconds(1))
    }
    #expect(runtime.received.isEmpty)
    await atom.stop()
  }

  @Test func anAbstainIsAnOutcomeNotAnError() async throws {
    let runtime = try FakeRuntime(plan: ["default": ["abstain": true]])
    let atom = client(runtime)
    let reply = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
    #expect(reply == .abstain("No valid point returned"))
    await atom.stop()
  }

  @Test func aRuntimeErrorCarriesItsExceptionType() async throws {
    let runtime = try FakeRuntime(plan: ["default": ["error": true]])
    let atom = client(runtime)
    await #expect(
      throws: AtomClient.Failure.runtime(type: "ValueError", message: "bad instruction")
    ) {
      try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
    }
    await atom.stop()
  }

  @Test func aRuntimeThatDiesFailsTheCallAndTheNextCallStartsAFreshOne() async throws {
    let runtime = try FakeRuntime(plan: ["1:1": ["exit": true]])
    let atom = client(runtime)
    do {
      _ = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
      Issue.record("expected the call to fail")
    } catch let failure as AtomClient.Failure {
      guard case .exited = failure else { throw failure }
    }
    let reply = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p9")
    #expect(reply == .point(AtomPoint(x: 9, y: 10)))
    #expect(runtime.starts.count == 2)
    await atom.stop()
  }

  @Test func anAbsentRuntimeIsUnavailableOnEveryCall() async {
    let atom = AtomClient(
      launch: AtomClient.Launch(executable: "/nonexistent/python", arguments: [], environment: [:]))
    for _ in 0..<2 {
      await #expect(throws: AtomClient.Failure.unavailable) {
        try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
      }
    }
  }

  @Test func healthAnswersWithoutLoadingTheModel() async throws {
    let runtime = try FakeRuntime()
    let atom = client(runtime)
    #expect(try await atom.health())
    await atom.stop()
  }

  @Test func stoppingWhileACallIsInFlightFailsItAndTheQueuedOnesInsteadOfHangingThem() async throws
  {
    let runtime = try FakeRuntime(plan: ["1:1": ["hang": true]])
    let atom = client(runtime, timeout: .seconds(30))
    let first = Task { try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1") }
    try await runtime.eventually("the request to arrive") {
      runtime.entries.contains { $0.kind == "in" }
    }
    let second = Task { try await atom.ground(imagePath: "/tmp/a.png", instruction: "p2") }
    try await Task.sleep(for: .milliseconds(50))
    await atom.stop()
    await #expect(throws: AtomClient.Failure.self) { try await first.value }
    await #expect(throws: AtomClient.Failure.self) { try await second.value }
    #expect(!alive(try #require(runtime.starts.first)))
  }

  @Test func aClientDroppedWithoutStopEndsItsProcess() async throws {
    let runtime = try FakeRuntime()
    let pid: Int
    do {
      let atom = client(runtime)
      _ = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
      pid = try #require(runtime.starts.first)
    }
    try await runtime.eventually("the process to end") { !alive(pid) }
  }

  @Test func stoppingEndsTheProcess() async throws {
    let runtime = try FakeRuntime()
    let atom = client(runtime)
    _ = try await atom.ground(imagePath: "/tmp/a.png", instruction: "p1")
    let pid = try #require(runtime.starts.first)
    await atom.stop()
    #expect(!alive(pid))
  }
}

struct AtomConfigTests {
  @Test func defaultsPointAtTheBarestateInstallAndTheBundledRuntime() {
    let config = AtomConfig.resolve(
      environment: [:], home: "/Users/x", resources: "/Applications/Photon.app/Contents/Resources",
      exists: { _ in true })
    let support = "/Users/x/Library/Application Support/Barestate"
    #expect(config?.python == "\(support)/Runtime/venv/bin/python")
    #expect(config?.runtime == "/Applications/Photon.app/Contents/Resources/atom/atom_runtime.py")
    #expect(config?.model == "\(support)/models/atom/tinyclick-4bit-v1/tinyclick-4bit")
  }

  @Test func environmentOverridesEachPath() {
    let config = AtomConfig.resolve(
      environment: [
        "BARESTATE_ATOM_PYTHON": "/p", "BARESTATE_ATOM_RUNTIME": "/r", "BARESTATE_ATOM_MODEL": "/m",
      ], home: "/Users/x", resources: nil, exists: { _ in true })
    #expect(config == AtomConfig(python: "/p", runtime: "/r", model: "/m"))
  }

  @Test func withoutABundleAndAnOverrideAtomIsAbsent() {
    let config = AtomConfig.resolve(
      environment: [:], home: "/Users/x", resources: nil, exists: { _ in true })
    #expect(config == nil)
  }

  @Test func anyMissingPathMeansAtomIsAbsent() {
    let config = AtomConfig.resolve(
      environment: [:], home: "/Users/x", resources: "/R",
      exists: { !$0.hasSuffix("atom_runtime.py") })
    #expect(config == nil)
  }

  @Test func theLaunchRunsTheRuntimeDirectlyWithOnlyTheModelDirectory() {
    let config = AtomConfig(python: "/p", runtime: "/r", model: "/m")
    #expect(config.launch.executable == "/p")
    #expect(config.launch.arguments == ["/r", "--model-dir", "/m"])
  }
}
