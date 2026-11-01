import BarestateCore
import Darwin
import Foundation
import Testing

/// AtomInstall against fake scripts: both streams merged in order, the one-line failure reason,
/// the display mapping for the script's machine lines, and cancel stopping the whole tree.
struct AtomInstallTests {
  private final class Scratch: @unchecked Sendable {
    let directory: URL

    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "atom-install-test-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func script(_ body: String) throws -> String {
      let url = directory.appendingPathComponent("script-\(UUID().uuidString).sh")
      try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      return url.path
    }

    func read(_ name: String) -> String {
      (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) {
      lock.lock()
      storage.append(line)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
  }

  /// Waits for a condition with a deadline, never a fixed sleep.
  private func until(
    _ what: String, seconds: Int = 5, _ condition: @escaping @Sendable () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
      if ContinuousClock.now >= deadline {
        Issue.record("timed out waiting for \(what)")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func linesFromBothStreamsArriveInOrderAndSuccessIsInstalled() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      echo out-1
      echo err-1 >&2
      echo out-2
      exit 0
      """)
    let lines = Lines()
    let outcome = await AtomInstall(script: script, environment: [:]).run { lines.append($0) }
    #expect(outcome == .installed)
    #expect(lines.all == ["out-1", "err-1", "out-2"])
  }

  @Test func theLastScriptLineIsTheFailureReason() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      echo step-one
      echo "setup-atom: needs 2500 MB free near /tmp/x, only 42 MB available" >&2
      exit 1
      """)
    let lines = Lines()
    let outcome = await AtomInstall(script: script, environment: [:]).run { lines.append($0) }
    #expect(outcome == .failed("needs 2500 MB free near /tmp/x, only 42 MB available"))
    #expect(lines.all == ["step-one", "needs 2500 MB free near /tmp/x, only 42 MB available"])
  }

  @Test func aModelErrorLineBecomesTheReasonAndProgressIsReadable() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      echo "setup-atom: installing the model" >&2
      echo '{"event": "progress", "bytes": 80, "total": 160, "file": "a.safetensors"}' >&2
      echo '{"ok": false, "error": "Model checksum mismatch: a.safetensors"}'
      exit 1
      """)
    let lines = Lines()
    let outcome = await AtomInstall(script: script, environment: [:]).run { lines.append($0) }
    #expect(outcome == .failed("Model checksum mismatch: a.safetensors"))
    #expect(
      lines.all == [
        "installing the model", "Installing the model · 50%",
        "Model checksum mismatch: a.safetensors",
      ])
  }

  @Test func aScriptThatWillNotStartFails() async {
    let outcome = await AtomInstall(script: "/no/such/script.sh", environment: [:]).run { _ in }
    #expect(outcome == .failed("The installer could not start."))
  }

  @Test func cancelStopsTheWholeTree() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      sleep 60 &
      echo $! > "$PID_FILE"
      echo "setup-atom: working"
      wait
      """)
    let install = AtomInstall(
      script: script, environment: ["PID_FILE": "\(scratch.directory.path)/child.pid"])
    let lines = Lines()
    async let outcome = install.run { lines.append($0) }
    try await until("the script to start") { !lines.all.isEmpty }
    let child = pid_t(scratch.read("child.pid"))
    #expect(child != nil && child! > 0)
    install.cancel()
    #expect(await outcome == .cancelled)
    try await until("the grandchild to be gone") { Darwin.kill(child!, 0) == -1 && errno == ESRCH }
  }

  @Test func cancelAndWaitLeavesNoDescendantEvenOneThatIgnoresTerm() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      sleep 60 &
      echo $! > "$PID_FILE"
      sh -c 'trap "" TERM; echo $$ > "$STUBBORN_FILE"; exec sleep 60' &
      until [ -s "$STUBBORN_FILE" ]; do sleep 0.01; done
      echo "setup-atom: working"
      wait
      """)
    let install = AtomInstall(
      script: script,
      environment: [
        "PID_FILE": "\(scratch.directory.path)/child.pid",
        "STUBBORN_FILE": "\(scratch.directory.path)/stubborn.pid",
      ])
    let lines = Lines()
    async let outcome = install.run { lines.append($0) }
    try await until("the script to start") { !lines.all.isEmpty }
    let children = try ["child.pid", "stubborn.pid"].map { name -> pid_t in
      try #require(pid_t(scratch.read(name)))
    }
    let started = ContinuousClock.now
    await install.cancelAndWait(timeout: .seconds(1))
    #expect(ContinuousClock.now - started < .seconds(3))
    for child in children { #expect(Darwin.kill(child, 0) == -1 && errno == ESRCH) }
    #expect(await outcome == .cancelled)
  }

  @Test func cancelEscalatesToSigkillForADescendantThatIgnoresTerm() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      sh -c 'trap "" TERM; echo $$ > "$STUBBORN_FILE"; exec sleep 60' &
      until [ -s "$STUBBORN_FILE" ]; do sleep 0.01; done
      echo "setup-atom: working"
      wait
      """)
    let install = AtomInstall(
      script: script, environment: ["STUBBORN_FILE": "\(scratch.directory.path)/stubborn.pid"])
    let lines = Lines()
    async let outcome = install.run { lines.append($0) }
    try await until("the script to start") { !lines.all.isEmpty }
    let stubborn = try #require(pid_t(scratch.read("stubborn.pid")))
    install.cancel()
    #expect(await outcome == .cancelled)
    try await until("the stubborn descendant to be killed", seconds: 6) {
      Darwin.kill(stubborn, 0) == -1 && errno == ESRCH
    }
  }

  @Test func aCancelThatBeatsTheLaunchNeverStartsTheScript() async throws {
    let scratch = try Scratch()
    let script = try scratch.script(
      """
      touch "$MARKER"
      exit 0
      """)
    let install = AtomInstall(
      script: script, environment: ["MARKER": "\(scratch.directory.path)/started.marker"])
    install.cancel()
    let outcome = await install.run { _ in }
    #expect(outcome == .cancelled)
    #expect(scratch.read("started.marker").isEmpty)
  }

  @Test func displayMapsTheScriptsMachineLines() {
    #expect(
      AtomInstall.display(line: "setup-atom: installing the runtime") == "installing the runtime")
    #expect(AtomInstall.display(line: "plain output") == "plain output")
    #expect(AtomInstall.display(line: "  ") == nil)
    #expect(
      AtomInstall.display(
        line: #"{"event": "progress", "bytes": 80, "total": 160, "file": "a"}"#)
        == "Installing the model · 50%")
    #expect(AtomInstall.display(line: #"{"ok": false, "error": "boom"}"#) == "boom")
    #expect(AtomInstall.display(line: #"{"ok": true, "result": {"installed": true}}"#) == nil)
  }
}
