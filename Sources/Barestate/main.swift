import AppKit
import BarestateCore
import CEFBridge
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String, code: Int32) -> Never {
  Log.error(.engine, "fatal \(message) exit=\(code)")
  FileHandle.standardError.write(Data("barestate: \(message)\n".utf8))
  exit(code)
}

let options: LaunchOptions
do {
  options = try LaunchOptions.parse(
    Array(CommandLine.arguments.dropFirst()), home: NSHomeDirectory())
} catch {
  fail("\(error)", code: 64)
}
let dataDir = options.dataDir

// Before anything is opened in the data dir: a second launch must not touch the live app's log,
// journal or browser profile.
if AppServer.isListening(at: dataDir.socket) {
  FileHandle.standardError.write(
    Data("barestate: another instance is already running on \(dataDir.socket)\n".utf8))
  exit(75)
}

guard BSCef.loadFrameworkInMain() else { fail("cannot load the CEF framework", code: 2) }

// The subclass must exist before CefInitialize: the first access decides the class.
let app = BarestateApplication.shared as! BarestateApplication
app.setActivationPolicy(.regular)
app.alwaysActive = options.testHooks

for directory in [dataDir.root, dataDir.profile, dataDir.tmp, dataDir.logs] {
  do {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  } catch {
    fail("cannot create \(directory): \(error)", code: 73)
  }
}

Log.start(logsDir: dataDir.logs)
Log.info(
  .engine,
  "launch version=\(AppController.version) pid=\(getpid()) dataDir=\(dataDir.root) "
    + "testHooks=\(options.testHooks) debug=\(Log.debugEnabled)")

// Closed explicitly before exit so SQLite checkpoints and removes the WAL files.
var store: Store?
do {
  store = try Store(path: dataDir.sqlite)
  Log.info(.store, "open")
} catch {
  fail("cannot open \(dataDir.sqlite): \(error)", code: 73)
}

app.appearance = NSAppearance(named: .aqua)

let controller = AppController(
  dataDir: dataDir,
  settings: Settings.loadOrCreate(path: dataDir.settings) {
    Log.error(.store, "settings.json \($0); using defaults")
  },
  startURL: options.url ?? "about:blank", testHooks: options.testHooks)
controller.database = { store }
if let store { controller.canvas.restore(store.loadCanvas()) }
controller.makeWindow()
controller.canvas.changed = { controller.refreshGraphViews() }
app.delegate = controller
app.controller = controller
app.mainMenu = makeMainMenu(controller: controller)

BSCef.onContextInitialized = { controller.contextInitialized() }
BSCef.onAddressChange = { id, url in
  controller.navigated(browserId: id, url: url)
  controller.update(browserId: id, commits: true) { $0.adopt(url: url) }
}
BSCef.onDocumentCommitted = { id in controller.previews.documentCommitted(browserId: id) }
BSCef.onTitleChange = { id, title in
  controller.update(browserId: id, commits: true) { $0.title = title }
}
BSCef.onLoadingStateChange = { id, loading, canGoBack, canGoForward in
  controller.update(browserId: id) {
    $0.loading = loading
    $0.canGoBack = canGoBack
    $0.canGoForward = canGoForward
  }
  if !loading { controller.loadFinished(browserId: id) }
}
BSCef.onFindResult = { id, count, active in
  controller.findResult(browserId: id, count: Int(count), active: Int(active))
}
BSCef.claimKeyEvent = { event, perform in
  guard let app = NSApp as? BarestateApplication else { return false }
  switch event.type {
  case .keyDown: return perform ? app.performShortcut(event) : app.isShortcut(event)
  case .keyUp: return app.swallowsKeyUp(event) || app.isShortcut(event)
  default: return false
  }
}
BSCef.onTakeFocus = { id, next in controller.pageGaveUpFocus(browserId: id, next: next) }
BSCef.onBrowserClosed = { id in controller.browserClosed(id) }
BSCef.onBeforePopup = { opener, url, background in
  controller.popupRequested(openerBrowserId: opener, url: url, background: background)
}
BSCef.onOpenURLInNewTab = { opener, url, background in
  controller.linkOpenedInNewTab(openerBrowserId: opener, url: url, background: background)
}
BSCef.onPopupCreated = { id, parent in controller.popupCreated(browserId: id, parent: parent) }
BSCef.onPopupAborted = { parent in controller.popupAborted(parent) }
BSCef.onLoadError = { id, code, text, url in
  controller.loadFailed(browserId: id, code: Int(code), text: text, url: url)
}
BSCef.onDevToolsMessage = { id, message in controller.tab(browserId: id)?.channel.receive(message) }

guard
  BSCef.initialize(
    withRootCachePath: dataDir.profile, logFile: dataDir.logs + "/cef.log",
    verbose: Log.debugEnabled)
else {
  fail("CefInitialize failed", code: 3)
}
Log.armCrashHandlers()
Log.info(.engine, "cef initialized")

let dispatcher = RPCDispatcher(testHooks: options.testHooks)
registerAppMethods(dispatcher, controller: controller)
registerControlMethods(dispatcher, controller: controller)
registerRunMethods(dispatcher, controller: controller)
let actions = Actions(controller: controller, store: { store })
registerActMethods(dispatcher, actions: actions)
registerMCPMethods(dispatcher, controller: controller)
registerEventMethods(dispatcher, controller: controller)
if options.testHooks {
  registerTestHooks(dispatcher, controller: controller, actions: actions, store: { store })
  registerCanvasHooks(dispatcher, controller: controller)
  registerPointerHooks(dispatcher, controller: controller)
  registerMotionHooks(dispatcher, controller: controller)
  registerPreviewHooks(dispatcher, controller: controller)
  registerModelHooks(dispatcher, controller: controller)
}
let server = AppServer(path: dataDir.socket, dispatcher: dispatcher)
do {
  try server.start()
} catch {
  fail("\(error)", code: 75)
}
// After the server: a second launch must fail on the socket before it touches a live journal.
do {
  if let closed = try store?.reconcile(), closed > 0 {
    Log.info(.runs, "reconciled \(closed) unfinished actions after restart")
  }
} catch {
  fail("cannot reconcile the journal: \(error)", code: 73)
}
do {
  try "\(getpid())\n".write(toFile: dataDir.pid, atomically: true, encoding: .utf8)
} catch {
  Log.error(.engine, "pid file not written: \(Log.describe(error))")
}

// SIGTERM and SIGINT quit through the same path as Cmd-Q; scripts/stop-app.sh relies on it.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
  signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    MainActor.assumeIsolated { controller.requestQuit("signal \(signalNumber)") }
  }
  source.resume()
  signalSources.append(source)
}

BSCef.runMessageLoop()

Log.info(.quit, "message loop ended")
server.stop()
unlink(dataDir.pid)
Log.info(.quit, "server stopped")
// A runtime hung in inference does not leave on stdin EOF, so it is killed here.
if let atom = actions.grounders.runningAtom {
  let stopped = DispatchSemaphore(value: 0)
  Task.detached {
    await atom.stop()
    stopped.signal()
  }
  stopped.wait()
  Log.info(.quit, "atom stopped")
}
if let installer = controller.installerStopping {
  let stopped = DispatchSemaphore(value: 0)
  Task.detached {
    await installer.value
    stopped.signal()
  }
  stopped.wait()
  Log.info(.quit, "installer stopped")
}
if let closing = store {
  Log.info(.quit, "store closing")
  // The actor finishes what it already accepted before it closes.
  let closed = DispatchSemaphore(value: 0)
  let saveCanvas = controller.canvas.finish()
  Task.detached {
    await saveCanvas()
    await closing.close()
    closed.signal()
  }
  closed.wait()
  store = nil
  Log.info(.quit, "store closed")
}
BSCef.shutdown()
Log.info(.quit, "exit code=0")
exit(0)
