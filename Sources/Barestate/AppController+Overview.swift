import AppKit
import BarestateCore
import CEFBridge

/// Switching between the overview and the focused page. Which pages exist, which is active and
/// where the camera is stay with TabStore and PageCanvas; this only decides what shows.
@MainActor
extension AppController {
  /// The node of the active page, if it has one.
  var activeNodeId: String? {
    activeTab.flatMap { canvas.graph.nodeId(forTab: $0.id) }
  }

  /// `settling` is the camera landing on a page: the one moment the live view appears.
  func applyPresentation(settling: Bool = false) {
    guard let root else { return }
    let focused = presentation == .focused
    let flying = camera.defersFocus && !settling
    // Each page view is hidden on its own, except a blank page that was never shown: hiding it
    // before it loaded leaves CEF unable to close it. The canvas covers it and it is no node.
    let blank = activeTab.map { AddressInput.isBlank($0.url) } ?? false
    if !flying {
      root.container.show(focused || blank ? activeTab?.view : nil)
      root.canvasView?.isHidden = focused
    }
    if focused {
      refreshChrome()
      // A launcher or find bar opened during the flight keeps the keyboard, and the activity view
      // keeps it until it is closed.
      let chromeHasFocus =
        activity.isOpen || settling && (launcher.isOpen || !root.findBar.isHidden)
      if let tab = activeTab, !flying, !chromeHasFocus { BSCef.focusBrowser(tab.browserId) }
    } else {
      closeFind()
      root.caption.show(nil)
      if !launcher.isOpen, !activity.isOpen { window?.makeFirstResponder(root) }
      root.focusContext.refresh()
      root.canvasView?.refresh()
    }
    toggles.check()
  }

  /// A key for the page that arrives while the page is still flying in. The keyboard stays with
  /// the window until the landing, so the move ends now: the page then gets this key and every
  /// later one in order, as human input on its own tab. Tab belongs to the key loop.
  func landForPageKey(_ event: NSEvent) {
    guard camera.defersFocus, presentation == .focused, event.window === window,
      window?.firstResponder === root, event.keyCode != 48
    else { return }
    if camera.settle() { applyPresentation(settling: true) }
  }

  // MARK: Leaving the page

  /// The page's last look is captured first, so the overview starts from it. Asked again while
  /// that runs, nothing changes: a pinch asks once per packet. Only a toggle takes the request
  /// back.
  func showOverview() {
    guard presentation == .focused, !quitting, leaving == nil else { return }
    let leavingId = activeTabId
    let leave = { [self] in
      camera.toOverview(of: activeNodeId) {
        presentation = .overview
        applyPresentation()
      }
    }
    // A page that is still flying in is not shown yet: there is nothing to capture.
    if camera.defersFocus { return leave() }
    leaving = Task {
      if let tab = activeTab {
        await previews.captureForOverview(tab)
      }
      guard !Task.isCancelled else { return }
      leaving = nil
      guard presentation == .focused, activeTabId == leavingId else { return }
      leave()
    }
  }

  // MARK: Entering a page

  /// Shows a page: a live node's own tab, or a new tab at the address of a closed one.
  func focusNode(_ id: String) {
    guard let node = canvas.graph.nodes.first(where: { $0.id == id }) else { return }
    if let tabId = node.tabId, tab(id: tabId) != nil {
      camera.toPage(of: id) { activate(tabId) }
      return
    }
    camera.toPage(of: id) {
      openTab(url: node.url, title: node.title, origin: .reopen(node: node.id))
    }
    notify("Reopened closed page")
  }

  /// ⌘⇧\ from the overview: the selected node, which starts as the active page.
  func focusSelection() {
    guard let id = root?.canvasView?.selection else { return }
    focusNode(id)
  }

  /// A message the person can see, and VoiceOver hears.
  func notify(_ text: String) {
    announce(text)
    root?.showNotice(text)
  }

  /// Redraws everything that shows the graph: the overview and the focused page's context.
  func refreshGraphViews() {
    guard let root else { return }
    root.setContext(activeNodeId.map { canvas.graph.context(of: $0) } ?? ([], []))
    root.focusContext?.refresh()
    root.canvasView?.refresh()
  }

  @objc func toggleOverview() {
    if presentation == .focused, let pending = leaving {
      pending.cancel()
      leaving = nil
      toggles.begin(toward: .focused)
      return toggles.check()
    }
    toggles.begin(toward: presentation == .overview ? .focused : .overview)
    perform(presentation == .overview ? .focusPage : .showOverview)
  }

  @objc func zoomInOverview() { perform(.zoomIn) }
  @objc func zoomOutOverview() { perform(.zoomOut) }
  @objc func zoomToFitOverview() { perform(.zoomToFit) }

  // MARK: Menus and shortcuts

  /// The command a menu item stands for, in the current presentation. The launcher, the menus and
  /// the shortcuts all ask `BrowserCommand.availability` about it, so none can do what another
  /// reports as unavailable.
  private func command(for action: Selector?) -> BrowserCommand? {
    switch action {
    case #selector(AppController.toggleOverview):
      return presentation == .overview ? .focusPage : .showOverview
    case #selector(AppController.zoomInOverview): return .zoomIn
    case #selector(AppController.zoomOutOverview): return .zoomOut
    case #selector(AppController.zoomToFitOverview): return .zoomToFit
    case #selector(AppController.goBack): return .back
    case #selector(AppController.goForward): return .forward
    case #selector(AppController.reloadPage): return .reload
    case #selector(AppController.showFind): return .find
    case #selector(AppController.reopenClosedTab): return .reopenClosed
    case #selector(AppController.showSettings): return .settings
    case #selector(AppController.showMuseActivity): return .showRunActivity
    case #selector(AppController.stopTask): return .stopRun
    // ⌘W closes Settings or About when one is on top, whatever the page.
    case #selector(AppController.closeActiveTab):
      return frontAuxiliaryWindow == nil ? .closePage : nil
    default: return nil
    }
  }

  /// Enables a command's menu item or says why not, in its tooltip.
  func validateCommandItem(_ item: NSMenuItem) -> Bool {
    guard let command = command(for: item.action) else { return true }
    if item.action == #selector(AppController.toggleOverview) {
      item.title = presentation == .overview ? "Show Page" : "Show Overview"
    }
    switch command.availability(in: commandContext()) {
    case .enabled:
      item.toolTip = nil
      return true
    case .disabled(let reason):
      item.toolTip = reason
      return false
    }
  }
}

/// Milliseconds from the ⌘⇧\ key-down at `sendEvent` until the presentation it asked for shows
/// and nothing is still moving. A landing starts its own fades after the camera ends, so a
/// settled state is confirmed one turn of the run loop later.
@MainActor
final class ToggleTimer {
  private(set) var times: [Double] = []
  private var asked: (at: UInt64, target: BrowserCommand.Presentation)?
  private let settled: (BrowserCommand.Presentation) -> Bool

  init(settled: @escaping (BrowserCommand.Presentation) -> Bool) { self.settled = settled }

  func begin(toward target: BrowserCommand.Presentation) {
    let now = DispatchTime.now().uptimeNanoseconds
    let stamp = (NSApp as? BarestateApplication)?.keyDownAt ?? 0
    asked = (now - stamp < 1_000_000_000 ? stamp : now, target)
  }

  func check() {
    guard let asked, settled(asked.target) else { return }
    DispatchQueue.main.async { [self] in
      guard let current = self.asked, current.at == asked.at, settled(asked.target) else { return }
      times.append(Double(DispatchTime.now().uptimeNanoseconds - asked.at) / 1e6)
      self.asked = nil
    }
  }

  func reset() {
    times = []
    asked = nil
  }
}
