import AppKit
import BarestateCore
import CEFBridge

/// What the menu, the command button and the launcher can ask the browser to do. Each command is
/// one method, so a shortcut and its button cannot drift apart.
@MainActor
extension AppController {
  func wireChrome(_ root: WindowRootView) {
    root.commandButton.onClick = { [weak self] in self?.newTab() }
    root.findBar.onQuery = { [weak self] in self?.findQueryChanged($0) }
    root.findBar.onStep = { [weak self] in self?.findStep(forward: $0) }
    root.findBar.onClose = { [weak self] in self?.closeFind() }
    root.window?.initialFirstResponder = root.commandButton
    root.onKeyLoopReturn = { [weak self] in
      guard let self, presentation == .focused, window?.firstResponder === root,
        let tab = activeTab
      else { return }
      BSCef.focusBrowser(tab.browserId)
    }
    runs.onChange = { [weak self] in self?.refreshChrome() }
    root.approvalCard.onDecide = { [weak self] item, allow in
      do {
        _ = try self?.decideApproval(item.id, allow: allow)
      } catch {
        Log.error(.runs, "approval \(item.id) not decided: \(Log.describe(error))")
      }
    }

    viewsById["root"] = root
    viewsById["commandButton"] = root.commandButton
    viewsById["caption"] = root.caption
    viewsById["findField"] = root.findBar
    for (id, view) in root.findBar.keyViews where id != "findField" { viewsById[id] = view }
    viewsById["canvasTitle"] = root.canvasView?.titleField
    viewsById["approvalCard"] = root.approvalCard
    viewsById["approvalAllow"] = root.approvalCard.allow
    viewsById["approvalDeny"] = root.approvalCard.deny
    viewsById["phoneChip"] = root.phoneChip
    viewsById["phoneDisconnect"] = root.phoneChip.disconnect
    root.phoneChip.disconnect.onClick = { [weak self] in self?.events.disconnectAll() }
  }

  // MARK: Chrome state

  func displayTitle(_ tab: Tab) -> String {
    if AddressInput.isBlank(tab.url) { return "New tab" }
    return tab.title.isEmpty ? tab.url : tab.title
  }

  func refreshChrome() {
    guard let root else { return }
    launcher.tabsChanged()
    root.caption.show(presentation == .focused ? activeTab?.caption : nil)
    refreshGraphViews()
    refreshApproval(animated: false)
    events.publish()
  }

  /// The chip follows the phone's session, and a screen reader hears when it starts or ends.
  func phoneSessionsChanged() {
    let connected = events.phoneConnected
    guard root?.phoneChip.shown != connected else { return }
    root?.phoneChip.setShown(connected, animated: true)
    announce(connected ? "Phone connected" : "Phone disconnected")
    launcher.tabsChanged()
  }

  /// The run the thinking orb follows: the newest one waiting for the model or acting. A takeover
  /// stops the run (takenOver), so an in-progress run here always still holds its page. Waiting
  /// for an approval is the card's moment, not the orb's.
  func refreshOrb() {
    let run = runs.runs.last { $0.state == .pending || $0.state == .running }
    root?.setOrb(run.map { ($0.id, $0.steps.last?.endedAt == nil && $0.steps.last != nil) })
  }

  // MARK: Page events from CEF

  /// `commits` marks the events that follow a committed navigation (address, title): only they
  /// feed the page graph, never the loading start that still holds the requested address.
  func update(browserId: Int32, commits: Bool = false, _ change: (Tab) -> Void) {
    guard let tab = tab(browserId: browserId) else { return }
    change(tab)
    tab.security = SSLState(rawValue: BSCef.sslState(inBrowser: browserId)) ?? .unknown
    // A tab whose browser is still closing is no longer a page of the graph.
    if commits, tabStore.tab(id: tab.id) != nil { canvas.tabChanged(tab) }
    refreshChrome()
  }

  func navigated(browserId: Int32, url: String) {
    guard let tab = tab(browserId: browserId) else { return }
    Log.info(.tabs, "navigate tab=\(tab.id) origin=\(Log.origin(url))")
  }

  func loadFailed(browserId: Int32, code: Int, text: String, url: String) {
    let tab = tab(browserId: browserId)
    let name = tab?.id ?? "browser\(browserId)"
    if let tab, SSLState.isCertificateNetError(code) {
      tab.certificateFailure = url
      refreshChrome()
    }
    Log.error(.engine, "load-error tab=\(name) code=\(code) text=\(text) origin=\(Log.origin(url))")
  }

  func loadFinished(browserId: Int32) {
    guard let tab = tab(browserId: browserId) else { return }
    Log.debug(.tabs, "loaded tab=\(tab.id)")
    // The same address can load again with a good certificate; the error page has its own URL.
    if tab.certificateFailure != nil, !tab.url.hasPrefix("chrome-error:"),
      tab.security == .secure || tab.security == .insecure
    {
      tab.certificateFailure = nil
      refreshChrome()
    }
    if presentation == .focused, tab.id == activeTabId { previews.captureSettled(tab) }
    guard AddressInput.isRecordable(tab.url), let store = database() else { return }
    let (url, title) = (tab.url, tab.title)
    Task {
      do {
        try await store.recordVisit(url: url, title: title, at: Date().timeIntervalSince1970)
      } catch {
        Log.error(.store, "record visit failed: \(Log.describe(error))")
      }
      launcher.storeChanged()
    }
  }

  // MARK: Navigation

  @objc func goBack() {
    guard let tab = activeTab else { return }
    humanInput(tabId: tab.id)
    BSCef.goBack(inBrowser: tab.browserId)
  }

  @objc func goForward() {
    guard let tab = activeTab else { return }
    humanInput(tabId: tab.id)
    BSCef.goForward(inBrowser: tab.browserId)
  }

  @objc func reloadPage() {
    guard let tab = activeTab else { return }
    humanInput(tabId: tab.id)
    root?.canvasView?.holdStill()
    BSCef.reloadBrowser(tab.browserId)
  }

  func pageFocus(_ tab: Tab) {
    guard !activity.isOpen else { return }
    if presentation == .focused {
      BSCef.focusBrowser(tab.browserId)
    } else if !launcher.isOpen {
      window?.makeFirstResponder(root)
    }
  }

  /// Tab left the page: the window's key loop goes on from the page's place in it. Chromium
  /// redispatches the unhandled Tab after this call returns, so moving focus now would let the new
  /// first responder take that same key and move on again.
  func pageGaveUpFocus(browserId: Int32, next: Bool) {
    guard let root, let page = tab(browserId: browserId), page.id == activeTabId else { return }
    Task {
      // A launcher or another control may have taken the keyboard since the Tab.
      guard BarestateApplication.tabId(containing: window?.firstResponder as? NSView) == page.id,
        let target = next ? root.nextValidKeyView : root.previousValidKeyView
      else { return }
      window?.makeFirstResponder(target)
    }
  }

  // MARK: Menu actions

  @objc func newTab() {
    launcher.open()
  }

  /// The launcher is the only place an address is typed; with a page open it starts with that
  /// page's address and navigates that page.
  @objc func openLocation() {
    launcher.open(location: true)
  }

  /// Loads an address in the tab a person typed it for. A tab that has gone gets a new one.
  func navigate(tab id: String, to url: String) {
    guard let tab = tab(id: id) else {
      openTab(url: url)
      return
    }
    humanInput(tabId: id)
    BSCef.loadURL(url, inBrowser: tab.browserId)
    if tab.id == activeTabId {
      presentation = .focused
      applyPresentation()
    }
    pageFocus(tab)
  }

  // MARK: Browser commands

  /// What `BrowserCommand.availability` reads, from the live tabs.
  func commandContext() -> BrowserCommand.Context {
    var context = BrowserCommand.Context()
    context.hasTab = activeTab != nil
    if let tab = activeTab {
      context.hasPage = !AddressInput.isBlank(tab.url)
      context.canGoBack = tab.canGoBack
      context.canGoForward = tab.canGoForward
    }
    context.hasClosedPage = !tabStore.closed.isEmpty
    context.presentation = presentation
    context.hasNode = root?.canvasView?.selection != nil
    context.activityView = true
    context.hasRuns = !runs.runs.isEmpty
    context.activeRun = runs.runs.last { $0.state.isInProgress }
    context.phoneConnected = events.phoneConnected
    return context
  }

  /// The launcher, the menus and the shortcuts run a command through the same methods.
  func perform(_ command: BrowserCommand) {
    guard command.availability(in: commandContext()) == .enabled else { return }
    switch command {
    case .back: goBack()
    case .forward: goForward()
    case .reload: reloadPage()
    case .history: launcher.showScope(.history)
    case .settings: showSettings()
    case .find: showFind()
    case .closePage: activeTabId.map(closeByPerson)
    case .reopenClosed: reopenClosedTab()
    case .showOverview: showOverview()
    case .focusPage: focusSelection()
    case .zoomIn: root?.canvasView?.zoom(by: CanvasView.zoomStep)
    case .zoomOut:
      if presentation == .focused {
        showOverview()
      } else {
        root?.canvasView?.zoom(by: 1 / CanvasView.zoomStep)
      }
    case .zoomToFit: root?.canvasView?.zoomToFit()
    case .stopRun:
      if let run = commandContext().activeRun { _ = try? runs.stop(run.id) }
    case .showRunActivity: activity.open()
    case .disconnectPhone: events.disconnectAll()
    }
  }

  @objc func showMuseActivity() { perform(.showRunActivity) }
  @objc func stopTask() { perform(.stopRun) }

  @objc func showAbout() {
    let credits = NSAttributedString(
      string: "by Barestate",
      attributes: [.font: Fonts.manrope(12), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Photon", .applicationIcon: Design.liftMark(height: 70),
      .credits: credits,
    ])
  }

  /// ⌘W closes what the person sees on top: Settings or About above the browser window, else the
  /// active tab. The key window cannot say. A locked or late-activating session reports none, or
  /// the browser window while Settings is still ordered above it, and ⌘W then closed a tab.
  @objc func closeActiveTab() {
    let aux = frontAuxiliaryWindow
    Log.info(
      .window,
      "close shortcut key=\(windowRole(NSApp.keyWindow)) front=\(windowRole(aux ?? window)) "
        + "target=\(aux == nil ? "tab" : windowRole(aux))")
    if let aux {
      aux.performClose(nil)
    } else if let id = activeTabId {
      closeByPerson(id)
    }
  }

  /// Settings or About, when it is ordered above the browser window. `orderedWindows` leaves the
  /// About panel out, so the front-to-back window numbers decide.
  var frontAuxiliaryWindow: NSWindow? {
    for number in NSWindow.windowNumbers(options: []) ?? [] {
      guard let other = NSApp.window(withWindowNumber: number.intValue), other.isVisible
      else { continue }
      if other === window { return nil }
      if other.styleMask.contains(.closable) { return other }
    }
    return nil
  }

  /// Window titles can carry page data, so the log names the role instead.
  private func windowRole(_ other: NSWindow?) -> String {
    guard let other else { return "none" }
    if other === window { return "browser" }
    return other === settingsWindow?.window ? "settings" : "other"
  }

  /// A window never has zero tabs: closing the last one leaves a blank tab, and ⌘⇧T can bring
  /// the closed one back.
  func closeByPerson(_ id: String) {
    if tabs.count == 1 { openTab(url: "about:blank") }
    closeTab(id, remember: true)
  }

  @objc func reopenClosedTab() {
    guard let entry = tabStore.popClosed() else { return }
    let revived = canvas.graph.lastArchivedId(url: entry.url).map { NewTabOrigin.reopen(node: $0) }
    openTab(
      url: entry.url, focus: presentation == .focused, at: entry.index, title: entry.title,
      origin: revived ?? .none)
  }

  // MARK: Editing

  /// A page is not an NSText, so the menu's editing commands go to its focused frame; anywhere
  /// else they go to the window's first responder. Only the page branch is human input: sendEvent
  /// skips its own bump for a shortcut, so the epoch moves here, before Chromium edits.
  private func edit(_ command: String, native: Selector) {
    let target = settingsWindow?.isFront == true ? settingsWindow?.window : window
    let focused = target?.firstResponder as? NSView
    if let tab = activeTab, BarestateApplication.tabId(containing: focused) == tab.id {
      humanInput(tabId: tab.id)
      BSCef.editCommand(command, inBrowser: tab.browserId)
    } else {
      // An explicit `to:` that cannot handle the selector raises NSInvalidArgumentException, which
      // Chromium turns into a crash; tryToPerform walks the responder chain and may find no one.
      _ = target?.firstResponder?.tryToPerform(native, with: nil)
    }
  }

  @objc func undoEdit() { edit("undo", native: Selector(("undo:"))) }
  @objc func redoEdit() { edit("redo", native: Selector(("redo:"))) }
  @objc func cutEdit() { edit("cut", native: #selector(NSText.cut(_:))) }
  @objc func copyEdit() { edit("copy", native: #selector(NSText.copy(_:))) }
  @objc func pasteEdit() { edit("paste", native: #selector(NSText.paste(_:))) }
  @objc func selectAllEdit() { edit("selectAll", native: #selector(NSText.selectAll(_:))) }

  @objc func selectNextTab() { activateCycled(by: 1) }
  @objc func selectPreviousTab() { activateCycled(by: -1) }

  private func activateCycled(by step: Int) {
    if let id = tabStore.order.cycled(by: step) {
      camera.cancel()
      activate(id, focus: presentation == .focused)
    }
  }

  @objc func selectTabByNumber(_ sender: NSMenuItem) {
    if let id = tabStore.order.shortcutTarget(sender.tag) {
      camera.cancel()
      activate(id, focus: presentation == .focused)
    }
  }

  /// ⌘D adds the page once; a second press finds it already there.
  @objc func bookmarkPage() {
    guard let tab = activeTab, AddressInput.isRecordable(tab.url), let store = database()
    else { return }
    let (url, title) = (tab.url, displayTitle(tab))
    Task {
      do {
        _ = try await store.addBookmark(url: url, title: title, at: Date().timeIntervalSince1970)
      } catch {
        Log.error(.store, "bookmark failed: \(Log.describe(error))")
      }
      launcher.storeChanged()
    }
  }

  @objc func showFind() {
    guard activeTab != nil, presentation == .focused else { return }
    root?.findBar.show()
  }

  // MARK: Find in page

  func findQueryChanged(_ text: String) {
    guard let tab = activeTab else { return }
    if text.isEmpty {
      BSCef.stopFinding(inBrowser: tab.browserId)
      root?.findBar.update(matches: 0, active: 0)
    } else {
      BSCef.find(text, forward: true, findNext: false, inBrowser: tab.browserId)
    }
  }

  func findStep(forward: Bool) {
    guard let tab = activeTab, let bar = root?.findBar, !bar.text.isEmpty else { return }
    BSCef.find(bar.text, forward: forward, findNext: true, inBrowser: tab.browserId)
  }

  func findResult(browserId: Int32, count: Int, active: Int) {
    guard browserId == activeTab?.browserId else { return }
    root?.findBar.update(matches: count, active: active)
  }

  func closeFind() {
    guard let bar = root?.findBar, !bar.isHidden else { return }
    let hadFocus = bar.hasFocus
    bar.hide()
    if let tab = activeTab {
      BSCef.stopFinding(inBrowser: tab.browserId)
      if hadFocus { pageFocus(tab) }
    }
  }
}
