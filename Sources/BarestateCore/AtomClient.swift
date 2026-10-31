import Darwin
import Foundation

/// A click on Atom's 0–999 grid.
public struct AtomPoint: Sendable, Equatable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  /// The grid is divided by 1000, not 999, and clamped to the last pixel.
  public func css(width: Double, height: Double) -> Point {
    Point(x: min(width - 1, x / 1000 * width), y: min(height - 1, y / 1000 * height))
  }
}

public enum AtomReply: Sendable, Equatable {
  case point(AtomPoint)
  case abstain(String)
}

/// Where the optional Atom runtime lives. Absent means the ladder skips it.
public struct AtomConfig: Sendable, Equatable {
  public let python: String
  public let runtime: String
  public let model: String

  public init(python: String, runtime: String, model: String) {
    self.python = python
    self.runtime = runtime
    self.model = model
  }

  public var launch: AtomClient.Launch {
    AtomClient.Launch(
      executable: python, arguments: [runtime, "--model-dir", model], environment: [:])
  }

  /// `resources` is the app bundle's Resources directory; its `atom/` folder holds the runtime.
  /// The model directory is the one `scripts/setup-atom.sh` installs into.
  public static func resolve(
    environment: [String: String], home: String, resources: String?,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> AtomConfig? {
    let support = "\(home)/Library/Application Support/Barestate"
    guard
      let runtime = environment["BARESTATE_ATOM_RUNTIME"]
        ?? resources.map({ "\($0)/atom/atom_runtime.py" })
    else { return nil }
    let config = AtomConfig(
      python: environment["BARESTATE_ATOM_PYTHON"] ?? "\(support)/Runtime/venv/bin/python",
      runtime: runtime,
      model: environment["BARESTATE_ATOM_MODEL"]
        ?? "\(support)/models/atom/tinyclick-4bit-v1/tinyclick-4bit")
    return [config.python, config.runtime, config.model].allSatisfy(exists) ? config : nil
  }
}

/// The Atom runtime behind JSON lines on stdio: one request in flight, ids echoed, anything that
/// cannot be matched to the pending request dropped.
public actor AtomClient {
  public struct Launch: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
    }
  }

  public enum Failure: Error, Equatable {
    case timeout
    case unavailable
    case exited(String)
    case runtime(type: String, message: String)
  }

  private enum Event: Sendable {
    case line(String)
    case exit(String)
  }

  /// Owns one child process. The stream preserves the order lines arrived in.
  private final class Child: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()

    var pid: pid_t { process.processIdentifier }

    init(_ launch: Launch) throws {
      (events, continuation) = AsyncStream.makeStream()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: launch.executable)
      process.arguments = launch.arguments
      process.environment = [
        "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
      ].merging(launch.environment) { $1 }
      process.standardInput = input
      process.standardOutput = output
      process.standardError = errors
      output.fileHandleForReading.readabilityHandler = { [self] handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          return
        }
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
          lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
          buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { continuation.yield(.line(line)) }
      }
      errors.fileHandleForReading.readabilityHandler = { [self] handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          return
        }
        lock.lock()
        errorTail = Data((errorTail + chunk).suffix(2048))
        lock.unlock()
      }
      process.terminationHandler = { [self] _ in
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let tail = String(decoding: errorTail, as: UTF8.self)
        lock.unlock()
        continuation.yield(.exit(tail))
        continuation.finish()
      }
      try process.run()
    }

    func send(_ line: String) throws {
      try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// SIGKILL, and return only once the process has been reaped.
    func kill() async {
      guard process.isRunning else { return }
      Darwin.kill(pid, SIGKILL)
      await Task.detached { [process] in process.waitUntilExit() }.value
    }
  }

  private struct Pending {
    let id: String
    let continuation: CheckedContinuation<[String: Any], Error>
  }

  private let launch: Launch
  private let warmTimeout: Duration
  private let coldTimeout: Duration
  private var child: Child?
  private var generation = 0
  private var warm = false
  private var counter = 0
  private var pending: Pending?
  private var busy = false
  private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
  private var nextWaiter = 0

  public init(
    launch: Launch, warmTimeout: Duration = .seconds(3), coldTimeout: Duration = .seconds(10)
  ) {
    self.launch = launch
    self.warmTimeout = warmTimeout
    self.coldTimeout = coldTimeout
    signal(SIGPIPE, SIG_IGN)
  }

  /// A client dropped without `stop()` must not strand its child: the runtime may be mid-request
  /// and never read the closed pipe.
  deinit {
    if let child, child.process.isRunning { Darwin.kill(child.pid, SIGKILL) }
  }

  public func ground(
    imagePath: String, instruction: String, deadline: ContinuousClock.Instant? = nil
  ) async throws -> AtomReply {
    let result = try await call(
      "ground", ["image_path": imagePath, "instruction": instruction], deadline: deadline)
    guard result["action"] as? String == "click",
      let grid = result["normalized"] as? [String: Any],
      let x = (grid["x"] as? NSNumber)?.doubleValue, let y = (grid["y"] as? NSNumber)?.doubleValue
    else { return .abstain(result["reason"] as? String ?? "no point") }
    guard (0...999).contains(x), (0...999).contains(y) else { return .abstain("off the grid") }
    return .point(AtomPoint(x: x, y: y))
  }

  public func health() async throws -> Bool {
    try await call("health", [:], deadline: nil)["verified"] as? Bool ?? false
  }

  public func stop() async {
    guard let child else { return }
    self.child = nil
    generation += 1
    let stranded = pending
    pending = nil
    stranded?.continuation.resume(throwing: Failure.exited("stopped"))
    let queued = waiters
    waiters = []
    for waiter in queued { waiter.continuation.resume(throwing: Failure.exited("stopped")) }
    try? child.input.fileHandleForWriting.close()
    await child.kill()
  }

  private func call(
    _ method: String, _ params: [String: Any], deadline: ContinuousClock.Instant?
  ) async throws -> [String: Any] {
    try await acquire(deadline)
    defer { release() }
    if let deadline, ContinuousClock.now >= deadline { throw Failure.timeout }
    return try await exchange(method, params)
  }

  /// Waiters whose deadline passes while queued are failed without ever being sent.
  private func acquire(_ deadline: ContinuousClock.Instant?) async throws {
    guard busy else {
      busy = true
      return
    }
    if let deadline, ContinuousClock.now >= deadline { throw Failure.timeout }
    nextWaiter += 1
    let id = nextWaiter
    let expiry = deadline.map { deadline in
      Task {
        try await Task.sleep(until: deadline)
        self.expire(waiter: id)
      }
    }
    defer { expiry?.cancel() }
    try await withCheckedThrowingContinuation { continuation in
      waiters.append((id, continuation))
    }
  }

  private func expire(waiter id: Int) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: Failure.timeout)
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func spawn() throws -> Child {
    if let child { return child }
    let started: Child
    do { started = try Child(launch) } catch { throw Failure.unavailable }
    child = started
    warm = false
    generation += 1
    let mine = generation
    // Weak: a strong reference would keep a dropped client, and so its child, alive until the
    // child exits.
    Task { [weak self] in
      for await event in started.events { await self?.handle(event, generation: mine) }
    }
    return started
  }

  private func exchange(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    let started = try spawn()
    counter += 1
    let id = String(counter)
    let timeout = warm ? warmTimeout : coldTimeout
    let line = String(
      decoding: try JSONSerialization.data(
        withJSONObject: ["id": id, "method": method, "params": params], options: [.sortedKeys]),
      as: UTF8.self)
    let timer = Task {
      try await Task.sleep(for: timeout)
      await self.timedOut(id)
    }
    defer { timer.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      pending = Pending(id: id, continuation: continuation)
      do { try started.send(line) } catch {
        pending = nil
        continuation.resume(throwing: Failure.exited("write failed"))
      }
    }
  }

  private func handle(_ event: Event, generation mine: Int) {
    guard mine == generation else { return }
    switch event {
    case .line(let text):
      guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let id = object["id"] as? String, let pending, pending.id == id
      else { return }
      self.pending = nil
      warm = true
      if object["ok"] as? Bool == true {
        pending.continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
      } else {
        let error = object["error"] as? [String: Any]
        pending.continuation.resume(
          throwing: Failure.runtime(
            type: error?["type"] as? String ?? "unknown",
            message: error?["message"] as? String ?? ""))
      }
    case .exit(let tail):
      child = nil
      guard let pending else { return }
      self.pending = nil
      pending.continuation.resume(throwing: Failure.exited(tail))
    }
  }

  /// There is no cancel: kill the process, wait for it to be gone, then start the next one warm.
  private func timedOut(_ id: String) async {
    guard let stuck = pending, stuck.id == id, let dying = child else { return }
    pending = nil
    child = nil
    generation += 1
    await dying.kill()
    _ = try? spawn()
    stuck.continuation.resume(throwing: Failure.timeout)
  }
}
