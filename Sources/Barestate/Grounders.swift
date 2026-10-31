import BarestateCore
import Foundation

/// The grounding rungs behind an `instruction` target (architecture §5.4, §5.8): Atom when its
/// runtime is installed, then Muse's computer tool. Every point either produces still has to pass
/// `PointAcceptance` before anything is clicked.
@MainActor
final class Grounders {
  /// What `test.grounding` can put in place of a real rung.
  enum Stub {
    case point(Point)
    case abstain
  }

  enum Resolution {
    case resolved(ref: Int, rung: Rung)
    case failed(reason: String)
  }

  private let controller: AppController
  private var client: AtomClient?
  private var clientLaunch: AtomClient.Launch?

  var policy = GroundingPolicy.measured
  var atomAbsent = false
  var atomLaunch: AtomClient.Launch?
  var atomStub: Stub?
  var museStub: Stub?
  private(set) var calls: [String] = []
  /// Safety checks Muse attached to the click it grounded, by tab, until the act is permitted.
  private var acks: [String: SafetyAck] = [:]
  /// The last Atom request, from sending to the parsed point (screenshot and file excluded).
  private(set) var clientMs = 0.0

  init(controller: AppController) { self.controller = controller }

  func resolve(instruction: String, tab: Tab, elements: [Element], session: String) async
    -> Resolution
  {
    let rejections = Rejections()
    acks[tab.id] = nil
    let result = await Ladder.resolve(
      instruction: instruction, elements: elements, atom: atom(instruction, tab),
      muse: muse(instruction, tab, session),
      accept: { x, y in
        let candidate = try? await PointProbe.candidate(x: x, y: y, transport: tab.channel)
        let verdict =
          candidate.map { PointAcceptance.evaluate(instruction, $0) } ?? .rejected(.noInteractive)
        if case .rejected(let why) = verdict { rejections.last = why }
        return verdict
      })
    switch result {
    case .resolved(let ref, let rung): return .resolved(ref: ref, rung: rung)
    case .needsHuman:
      acks[tab.id] = nil
      return .failed(reason: rejections.last?.reason ?? "needs-human")
    }
  }

  /// The checks of the click that was just grounded; the caller owns acknowledging them.
  func takeAck(_ tab: Tab) -> SafetyAck? {
    defer { acks[tab.id] = nil }
    return acks[tab.id]
  }

  /// Sent once, after the permission layer allowed the click it belongs to.
  func acknowledge(_ ack: SafetyAck, tab: Tab, session: String) async {
    do {
      try await MuseGrounder(model: controller.modelClient(session: session)).acknowledge(
        ack, transport: tab.channel)
      Log.info(.runs, "acknowledged \(ack.checks.count) safety checks tab=\(tab.id)")
    } catch {
      Log.info(.runs, "could not acknowledge safety checks: \(Log.describe(error))")
    }
  }

  /// One grounding exactly as an act would run it, for the FT4 measurement.
  func measure(instruction: String, tab: Tab) async -> (
    point: Point?, verdict: PointVerdict?, atomMs: Double
  ) {
    guard let ground = atom(instruction, tab) else { return (nil, nil, 0) }
    let started = ContinuousClock.now
    let point = await ground()
    let atomMs = started.duration(to: .now).milliseconds
    guard let point else { return (nil, nil, atomMs) }
    let candidate = try? await PointProbe.candidate(x: point.x, y: point.y, transport: tab.channel)
    return (
      point,
      candidate.map { PointAcceptance.evaluate(instruction, $0) } ?? .rejected(.noInteractive),
      atomMs
    )
  }

  private final class Rejections {
    var last: PointRejection?
  }

  private func launch() -> AtomClient.Launch? {
    if atomAbsent { return nil }
    if let atomLaunch { return atomLaunch }
    let environment = ProcessInfo.processInfo.environment
    return AtomConfig.resolve(
      environment: environment, home: NSHomeDirectory(), resources: Bundle.main.resourcePath
    )?.launch
  }

  /// nil means the runtime is not installed, and the ladder skips the rung.
  private func atom(_ instruction: String, _ tab: Tab) -> Ladder.Ground? {
    if let atomStub { return stubbed(atomStub, "atom", instruction) }
    guard let launch = launch() else { return nil }
    return { @MainActor [self] in
      calls.append("atom: \(instruction)")
      do {
        let shot = try await Screenshot.capture(tab.channel)
        let path = "\(controller.dataDir.tmp)/atom-\(UUID().uuidString).png"
        try shot.png.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let started = ContinuousClock.now
        let reply = try await atomClient(launch).ground(imagePath: path, instruction: instruction)
        clientMs = started.duration(to: .now).milliseconds
        guard case .point(let grid) = reply else { return nil }
        return grid.css(width: shot.cssWidth, height: shot.cssHeight)
      } catch {
        Log.info(.runs, "atom could not ground: \(Log.describe(error))")
        return nil
      }
    }
  }

  private func atomClient(_ launch: AtomClient.Launch) -> AtomClient {
    if let client, clientLaunch?.executable == launch.executable,
      clientLaunch?.arguments == launch.arguments, clientLaunch?.environment == launch.environment
    {
      return client
    }
    let replacement = AtomClient(launch: launch)
    let old = client
    client = replacement
    clientLaunch = launch
    if let old { Task { await old.stop() } }
    return replacement
  }

  private func muse(_ instruction: String, _ tab: Tab, _ session: String) -> Ladder.Ground? {
    if let museStub { return stubbed(museStub, "muse", instruction) }
    return { @MainActor [self] in
      calls.append("muse: \(instruction)")
      do {
        return try await MuseGrounder(model: controller.modelClient(session: session)).ground(
          instruction, transport: tab.channel,
          onChecks: { [self] in
            acks[tab.id] = $0
            Log.info(.runs, "muse click carries \($0.checks.count) safety checks tab=\(tab.id)")
          })
      } catch {
        Log.info(.runs, "muse could not ground: \(Log.describe(error))")
        return nil
      }
    }
  }

  private func stubbed(_ stub: Stub?, _ name: String, _ instruction: String) -> Ladder.Ground {
    { @MainActor [self] in
      calls.append("\(name): \(instruction)")
      if case .point(let point) = stub { return point }
      return nil
    }
  }

  /// The Atom process client, if one was started; quitting stops it off the main thread.
  var runningAtom: AtomClient? { client }

  func stop() async { await client?.stop() }

  func reset() async {
    atomAbsent = false
    atomLaunch = nil
    atomStub = nil
    museStub = nil
    policy = .measured
    calls = []
    acks = [:]
    await stop()
    client = nil
    clientLaunch = nil
  }
}

extension Duration {
  var milliseconds: Double {
    Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
  }
}
