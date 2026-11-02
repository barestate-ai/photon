import AppKit
import BarestateCore
import CEFBridge

/// Owns the window, the tabs and the quit sequence. Everything here runs on the main thread,
/// which is also CEF's UI thread.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static let version = "0.1.0"

  let dataDir: DataDir
  var settings: Settings
  let tabStore = TabStore()
  private(set) var window: NSWindow?
  private(set) var root: WindowRootView?
  private(set) var ready = false
  /// Test hooks address views by id: the chrome controls and every tab id.
  var viewsById: [String: NSView] = [:]
  var reduceMotion = false
  var settingsWindow: SettingsWindow?
  let runs = RunController()
  private(set) lazy var remote = RemoteController(app: self)
  private(set) lazy var approvals: Approvals = {
    let approvals = Approvals()
    approvals.onChange = { [unowned self] in
      refreshApproval()
      events.publish()
    }
    return approvals
  }()
  private(set) lazy var events = EventHub(app: self)
  private(set) lazy var launcher = LauncherController(app: self)
  private(set) lazy var activity = RunActivityController(app: self)
  private(set) lazy var canvas = PageCanvas(store: { [unowned self] in self.database() })
  private(set) lazy var previews = Previews(app: self)
  /// Popup views handed to CEF whose browser does not exist yet, by view.
  var pendingPopups: [ObjectIdentifier: PendingPopup] = [:]
  /// Every accessibility announcement the app asked for, for `test.announcements`.
  private(set) var announcements: [String] = []
  /// Set by `test.modelOffline`: Start task cannot reach Muse.
  var modelOffline = false
  /// A run's model call failed as an outage; only Retry clears it (`retryMuse`).
  var modelLatched = false
  let network = NetworkPath()
  private(set) lazy var spendLedger = SpendLedger(
    path: ProcessInfo.processInfo.environment["BARESTATE_SPEND_LOG"] ?? dataDir.spend)
  /// Chrome text and its controls grow with it (`test.textScale`); page content does not.
  var textScale = 1.0 {
    didSet {
      Fonts.scale = CGFloat(textScale)
      root?.applyTextScale()
    }
  }
  /// Overview or the focused page, which is always the active tab. Not saved: a launch starts on
  /// the overview.
  var presentation = BrowserCommand.Presentation.overview {
    didSet { if presentation == .overview { fillsWindow = false } }
  }
  /// The focused page fills the window (Full window). Only a focused page can; the overview ends it.
  var fillsWindow = false {
    didSet {
      root?.fillsWindow = fillsWindow
      if !fillsWindow { maximizedFromOverview = false }
    }
  }
  /// The page took the window straight from its card in the overview, so leaving Full window
  /// goes back to that card.
  var maximizedFromOverview = false
  var viewLevel: ViewLevel { ViewLevel(presentation, fillsWindow: fillsWindow) }
  /// The one step a pinch out has taken so far, so the rest of the same gesture does not take another.
  var pinchStepped = false
  /// The card the last plain click opened and where, so a double-click can reach it after the
  /// canvas has gone.
  var cardClick: (node: String, point: CGPoint)?
  /// Whether the empty canvas has shown its first-run hint: once it has, it never shows again.
  var hintState = HintState.unseen
  enum HintState { case unseen, showing, done }
  private(set) lazy var camera = CameraTransition(app: self)
  /// Times ⌘⇧\ and ⌘↩ from the key-down to a settled view level, for `test.toggleTimings`.
  private(set) lazy var toggles = ToggleTimer { [unowned self] target in
    viewLevel == target && MotionLedger.shared.inFlight.isEmpty
  }
  /// The page's last look being captured (for at most `Motion.previewCaptureTimeout`) before the
  /// overview replaces it.
  var leaving: Task<Void, Never>?
  /// The same wait before a page takes the window or gives it back.
  var filling: Task<Void, Never>?
  /// Set by main: the app owns the only reference so the database closes before exit.
  var database: @MainActor () -> Store? = { nil }
  private var closing: [Int32: Tab] = [:]
  private(set) var quitting = false
  /// The Atom installer being stopped by a quit; main waits for it before exiting.
  private(set) var installerStopping: Task<Void, Never>?
  private let startURL: String
  let testHooks: Bool

  init(dataDir: DataDir, settings: Settings, startURL: String, testHooks: Bool) {
    self.dataDir = dataDir
    self.settings = settings
    self.startURL = startURL
    self.testHooks = testHooks
  }

  /// Browsers CEF holds: one per page, plus any still closing. Never one per card.
  var cefBrowserCount: Int { tabs.count + closing.count }
  var tabs: [Tab] { tabStore.tabs }
  var activeTabId: String? { tabStore.activeId }
  var activeTab: Tab? { tabStore.active }
  var container: ContentContainerView? { root?.container }

  func makeWindow() {
    Fonts.registerBundled()
    let window = BarestateWindow(
      contentRect: NSRect(x: 200, y: 200, width: 1100, height: 760),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.alwaysKey = testHooks
    window.title = "Photon"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentMinSize = NSSize(width: 720, height: 600)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.acceptsMouseMovedEvents = true
    window.delegate = self
    window.isReleasedWhenClosed = false
    // Nothing may be written outside the data dir, and window restoration writes to
    // ~/Library/Saved Application State.
    window.isRestorable = false
    let root = WindowRootView(frame: window.contentLayoutRect)
    root.install(CanvasView(app: self), focus: FocusContextView(app: self))
    window.contentView = root
    self.window = window
    self.root = root
    root.camera = camera
    MotionLedger.shared.reduced = { [unowned self] in self.motionReduced }
    MotionLedger.shared.onIdle = { [unowned self] in toggles.check() }
    wireChrome(root)
    launcher.wire(root.launcher)
    activity.wire(root.activity)
    tabStore.onChange = { [weak self] in self?.refreshChrome() }
    events.onSessionsChanged = { [weak self] in self?.phoneSessionsChanged() }
    // A system Reduce Motion change must stop a pulse that is already running.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshGraphViews() } }
  }

  func contextInitialized() {
    network.start()
    hintState = FileManager.default.fileExists(atPath: dataDir.hintSeen) ? .done : .unseen
    window?.makeKeyAndOrderFront(nil)
    activateApp()
    openTab(url: startURL)
    applyPresentation()
    if presentation == .overview, canvas.graph.nodes.isEmpty { root?.playFirstRun() }
    Task { await launcher.reload() }
    ready = true
  }

  func clearAnnouncements() { announcements = [] }

  func announce(_ text: String) {
    announcements.append(text)
    NSAccessibility.post(
      element: window as Any, notification: .announcementRequested,
      userInfo: [.announcement: text])
  }

  /// Chromium drops mouse input while the app is inactive, and the cooperative activate() does
  /// not take focus from whichever app a test run was started from.
  func activateApp() {
    window?.makeKeyAndOrderFront(nil)
    if testHooks {
      NSApp.activate(ignoringOtherApps: true)
    } else {
      NSApp.activate()
    }
  }

  @discardableResult
  func openTab(
    url: String, activate: Bool = true, focus: Bool? = nil, at index: Int? = nil,
    title: String = "", origin: NewTabOrigin = .none
  ) -> Tab? {
    guard let view = makeContentView(activate: activate) else { return nil }
    let id = BSCef.createBrowser(in: view, url: url)
    guard id != 0 else {
      Log.error(.engine, "create browser failed origin=\(Log.origin(url))")
      view.removeFromSuperview()
      return nil
    }
    return adopt(
      browserId: id, view: view, url: url, title: title, activate: activate, focus: focus,
      at: index, origin: origin)
  }

  func makeContentView(activate: Bool) -> TabContentView? {
    guard let container else { return nil }
    let view = TabContentView(frame: root?.pageRect ?? container.bounds)
    view.isHidden = !activate
    container.addSubview(view)
    return view
  }

  /// Registers a browser that now exists in `view` as a tab. `focus` says whether an activated
  /// tab also takes the screen; it defaults to `activate`.
  @discardableResult
  func adopt(
    browserId id: Int32, view: TabContentView, url: String, title: String, activate: Bool,
    focus: Bool? = nil, at index: Int?, origin: NewTabOrigin
  ) -> Tab {
    let tab = Tab(browserId: id, view: view, url: url)
    tab.title = title
    tab.origin = origin
    viewsById[tab.id] = view
    tab.controlChanged = { [weak self] in self?.reapApprovals() }
    if activate { closeFind() }
    tabStore.add(tab, at: index, activate: activate || tabStore.activeId == nil)
    if tabStore.activeId == tab.id { present(tab, focus: focus ?? activate) }
    Log.info(
      .tabs,
      "create tab=\(tab.id) browser=\(id) active=\(tabStore.activeId == tab.id) "
        + "origin=\(Log.origin(url)) count=\(tabs.count)")
    return tab
  }

  /// `focus` shows the page too; closing the active page passes false and stays where it was.
  func activate(_ id: String, focus: Bool = true) {
    guard let tab = tab(id: id) else { return }
    Log.info(.tabs, "activate tab=\(id)")
    closeFind()
    tabStore.activate(id)
    present(tab, focus: focus)
    root?.canvasView?.followActive(reveal: presentation == .overview)
  }

  /// A blank page is never shown as a page: it is the empty canvas.
  private func present(_ tab: Tab, focus: Bool) {
    if AddressInput.isBlank(tab.url) {
      presentation = .overview
    } else if focus {
      presentation = .focused
    }
    applyPresentation()
  }

  /// The view is hidden at once; CEF finishes closing in the background.
  func closeTab(_ id: String, remember: Bool = false) {
    guard let tab = tab(id: id) else { return }
    Log.info(.tabs, "close tab=\(id) remember=\(remember)")
    closing[tab.browserId] = tab
    removeFromTabs(tab, remember: remember)
    BSCef.closeBrowser(tab.browserId)
  }

  private func removeFromTabs(_ tab: Tab, remember: Bool = false) {
    let wasActive = tabStore.activeId == tab.id
    guard tabStore.remove(tab, remember: remember) != nil else { return }
    canvas.tabClosed(tab.id)
    reapApprovals()
    tab.view.isHidden = true
    if wasActive && !quitting, let next = tabStore.activeId { activate(next, focus: false) }
  }

  func tab(id: String) -> Tab? {
    tabStore.tab(id: id)
  }

  func tab(browserId: Int32) -> Tab? {
    tabs.first { $0.browserId == browserId } ?? closing[browserId]
  }

  func humanInput(tabId: String) {
    guard let tab = tab(id: tabId) else { return }
    let held = tab.control.controller
    tab.control.humanInput()
    tab.lastHumanInputMs = Date().timeIntervalSince1970 * 1000
    runs.takenOver(from: held)
  }

  func browserClosed(_ browserId: Int32) {
    if let tab = tab(browserId: browserId) {
      // The page can close itself (window.close), so the tab may still be live here.
      removeFromTabs(tab)
      closing[browserId] = nil
      tab.channel.close()
      tab.view.removeFromSuperview()
      viewsById[tab.id] = nil
      Log.info(.tabs, "closed tab=\(tab.id) browser=\(browserId) left=\(tabs.count)")
    } else {
      Log.debug(.tabs, "closed unknown browser=\(browserId)")
    }
    if quitting && tabs.isEmpty && closing.isEmpty {
      Log.info(.quit, "quitting message loop")
      BSCef.quitMessageLoop()
    }
  }

  /// Closes every browser first: quitting the loop with a live browser hangs CefShutdown.
  func requestQuit(_ reason: String) {
    guard !quitting else { return }
    quitting = true
    remote.disable(wait: true)
    installerStopping = settingsWindow?.stopInstaller()
    Log.info(
      .quit,
      "request reason=\(reason) tabs=\(tabs.count) installer=\(installerStopping != nil)")
    for tab in tabs { closeTab(tab.id) }
    if closing.isEmpty {
      Log.info(.quit, "quitting message loop")
      BSCef.quitMessageLoop()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    requestQuit("terminate")
    return .terminateCancel
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestQuit("window-close")
    return false
  }

  /// Native full screen has no title bar, so a page that fills the window loses its top inset;
  /// the frame change alone does not say so.
  func windowDidEnterFullScreen(_ notification: Notification) { root?.layoutChildren() }
  func windowDidExitFullScreen(_ notification: Notification) { root?.layoutChildren() }

  /// The launcher field gets its own editor: the window's shared one also serves the find bar,
  /// and the inset and whole-glyph metrics below belong to the launcher's 18 pt type only.
  private lazy var launcherEditor: NSTextView = {
    let editor = LauncherEditor(frame: .zero)
    editor.isFieldEditor = true
    // The default hinted whole-point advances squeeze some words against each other on a 1x
    // display; the font's real advances keep one even weight.
    editor.layoutManager?.usesScreenFonts = false
    editor.textContainerInset = NSSize(width: 0, height: 3)
    return editor
  }()

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    guard let client = client as? NSTextField, client === root?.launcher.field else { return nil }
    return launcherEditor
  }
}
