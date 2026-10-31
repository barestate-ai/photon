import BarestateCore
import CEFBridge
import Darwin
import Foundation
import os

enum LogCategory: String, CaseIterable {
  case engine, tabs, launcher, canvas, runs, approvals, remote, store, quit, window
}

/// Every event goes to the unified log (subsystem ai.barestate.photon) and to
/// `<data-dir>/logs/photon.log`. Messages carry ids, counts, codes and `Log.origin` addresses
/// only: never a full URL, page content, typed text, observation text, token or key.
enum Log {
  static let subsystem = "ai.barestate.photon"
  nonisolated(unsafe) private(set) static var debugEnabled = false
  nonisolated(unsafe) private static var file: LogFile?
  private static let loggers = Dictionary(
    uniqueKeysWithValues: LogCategory.allCases.map {
      ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

  /// `BARESTATE_LOG=debug` also turns on debug events here and verbose CEF logging.
  static func start(logsDir: String) {
    debugEnabled = ProcessInfo.processInfo.environment["BARESTATE_LOG"] == "debug"
    file = LogFile(path: logsDir + "/photon.log")
    crashDescriptor = file?.descriptor ?? -1
    crashLines.initialize(repeating: nil, count: 32)
    for number in fatalSignals {
      crashLines[Int(number)] = strdup("fatal signal \(signalName(number)) pid=\(getpid())\n")
    }
    armCrashHandlers()
    BSApplication.onReportException = { Log.exception($0, via: "reportException") }
  }

  /// Chromium installs its own handlers during CefInitialize, so this runs again after it.
  static func armCrashHandlers() {
    NSSetUncaughtExceptionHandler { Log.exception($0, via: "handler") }
    for number in fatalSignals {
      var action = sigaction()
      action.__sigaction_u.__sa_handler = fatalSignalHandler
      action.sa_flags = SA_NODEFER
      sigaction(number, &action, nil)
    }
  }

  static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
    emit("info", category, message())
  }

  static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
    emit("error", category, message())
  }

  static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
    if debugEnabled { emit("debug", category, message()) }
  }

  static func origin(_ url: String) -> String { LogFile.origin(url) }

  /// The error's type, plus the journal's own message; other messages can quote page data.
  static func describe(_ error: Error) -> String {
    if let failure = error as? Store.Failure { return "Store.Failure \(failure.message)" }
    let code = (error as NSError).code
    return "\(type(of: error)) code=\(code)"
  }

  /// Synchronous: the process may be about to die.
  static func exception(_ exception: NSException, via: String) {
    let stack = exception.callStackSymbols.joined(separator: " | ")
    error(
      .engine,
      "uncaught exception via=\(via) name=\(exception.name.rawValue) "
        + "reason=\(exception.reason ?? "") stack=\(stack)")
  }

  private static func emit(_ level: String, _ category: LogCategory, _ message: String) {
    let logger = loggers[category]!
    switch level {
    case "error": logger.error("\(message, privacy: .public)")
    case "debug": logger.debug("\(message, privacy: .public)")
    default: logger.info("\(message, privacy: .public)")
    }
    file?.append(level: level, category: category.rawValue, message: message)
  }
}

private let fatalSignals = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP]
nonisolated(unsafe) private var crashDescriptor: Int32 = -1
// Built before any handler can run: a handler may not allocate, format or take a lock.
nonisolated(unsafe) private var crashLines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  .allocate(capacity: 32)

private func fatalSignalHandler(_ number: Int32) {
  if number > 0, number < 32, let line = crashLines[Int(number)] {
    _ = write(crashDescriptor, line, strlen(line))
  }
  signal(number, SIG_DFL)
  raise(number)
}

private func signalName(_ number: Int32) -> String {
  switch number {
  case SIGSEGV: "SIGSEGV"
  case SIGBUS: "SIGBUS"
  case SIGILL: "SIGILL"
  case SIGABRT: "SIGABRT"
  default: "SIGTRAP"
  }
}
