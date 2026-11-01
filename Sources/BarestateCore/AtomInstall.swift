import Darwin
import Foundation

/// One run of the bundled `setup-atom.sh all`: executed directly (argv only, no shell string) with
/// the app's environment inherited, so the `BARESTATE_RUNTIME_DIR` / `BARESTATE_ATOM_MODEL` /
/// `ATOM_ARCHIVE` overrides ride along. Both streams surface as short display lines, and cancel
/// stops the whole process tree so a retry can start at once.
public final class AtomInstall: @unchecked Sendable {
  public enum Outcome: Sendable, Equatable {
    case installed
    case cancelled
    case failed(String)
  }

  private let process = Process()
  private let output = Pipe()
  private let lock = NSLock()
  /// Written only by the line reader, read only after it ends at EOF: no lock needed.
  private var lastLine: String?
  private var cancelled = false

  public init(script: String, environment: [String: String]? = nil) {
    process.executableURL = URL(fileURLWithPath: script)
    process.arguments = ["all"]
    // nil inherits the parent's environment; an explicit dictionary replaces it (tests).
    if let environment { process.environment = environment }
    // One pipe for both streams keeps the arrival order across them.
    process.standardOutput = output
    process.standardError = output
  }

  /// A dropped installer must not strand the script: it would keep writing into the target dirs.
  deinit {
    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
  }

  /// Resolves once the script exits and its output is drained. `onLine` fires on an arbitrary
  /// thread with each display line, in arrival order.
  public func run(onLine: @escaping @Sendable (String) -> Void) async -> Outcome {
    // A cancel that beat the launch: never start.
    if lock.withLock({ cancelled }) { return .cancelled }
    do {
      try process.run()
      // The parent never writes; without this close our own write end would keep the pipe
      // open and the line reader would never see EOF.
      try output.fileHandleForWriting.close()
    } catch {
      return .failed("The installer could not start.")
    }
    // One reader from launch to EOF: no second drain can race or reorder the final lines.
    async let drained: Void = readLines(onLine)
    let status: Int32 = await withCheckedContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
    }
    // EOF follows once every write end closes: bash reaps its own children on exit, and cancel
    // SIGTERMs the tree first, so the drain ends with the tree.
    await drained
    if lock.withLock({ cancelled }) { return .cancelled }
    guard status == 0 else {
      return .failed(lastLine ?? "The installer exited with code \(status).")
    }
    return .installed
  }

  private func readLines(_ onLine: @Sendable (String) -> Void) async {
    // A read error ends the stream early; the exit status still decides the outcome.
    var iterator = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
    while let raw = try? await iterator.next() {
      guard let line = Self.display(line: raw) else { continue }
      lastLine = line
      onLine(line)
    }
  }

  /// SIGTERM to the whole tree, children first, so the script's own TERM trap cleans up its temp
  /// dirs; SIGKILL to the script if it is still around two seconds later.
  public func cancel() {
    lock.withLock { cancelled = true }
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    for descendant in Self.tree(rootedAt: pid) { Darwin.kill(descendant, SIGTERM) }
    Task.detached { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, self.process.isRunning else { return }
      Darwin.kill(pid, SIGKILL)
    }
  }

  /// The one line the UI shows for a raw output line, or nil when the line is machine-only.
  public static func display(line raw: String) -> String? {
    var line = raw
    if line.hasSuffix("\r") { line.removeLast() }
    if line.hasPrefix("setup-atom: ") { line.removeFirst("setup-atom: ".count) }
    guard line.hasPrefix("{"), let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line }
    if object["event"] as? String == "progress",
      let bytes = (object["bytes"] as? NSNumber)?.int64Value,
      let total = (object["total"] as? NSNumber)?.int64Value, total > 0
    {
      return "Installing the model · \(bytes * 100 / total)%"
    }
    if let error = object["error"] as? String { return error }
    return nil
  }

  /// Children before their parents, the root last, so a signal sweep stops the leaves first.
  private static func tree(rootedAt root: pid_t) -> [pid_t] {
    var ordered: [pid_t] = []
    var pending: [pid_t] = [root]
    while let pid = pending.popLast() {
      ordered.append(pid)
      pending.append(contentsOf: children(of: pid))
    }
    return ordered.reversed()
  }

  private static func children(of pid: pid_t) -> [pid_t] {
    let stride = Int32(MemoryLayout<pid_t>.stride)
    let size = proc_listchildpids(pid, nil, 0)
    guard size > 0 else { return [] }
    var buffer = [pid_t](repeating: 0, count: Int(size / stride) + 16)
    // The return is a pid count on this macOS, not the documented bytes; never trust entries
    // past it, and never signal pid 0 (that is our own process group).
    let found = proc_listchildpids(pid, &buffer, Int32(buffer.count) * stride)
    guard found > 0 else { return [] }
    return buffer.prefix(Int(found)).filter { $0 > 0 }
  }
}
