import AppKit
import BarestateCore

/// Full window: the focused page filling the window below the title bar. It is the same live view
/// in a bigger frame, so going in and out never reloads the page.
@MainActor
extension AppController {
  static let firstRunHint =
    "click a page to open it · hover it and click ⤢ to maximize · pinch out or ⌘⇧\\ for the overview"

  /// ⌘↩: opens the focused page in Full window, the selected card from the overview, or leaves it.
  @objc func toggleFullWindow() {
    guard viewLevel.canToggleFullWindow(hasSelection: root?.canvasView?.selection != nil) else {
      return
    }
    toggles.begin(
      toward: viewLevel == .fullWindow
        ? viewLevel.exited(maximizedFromOverview: maximizedFromOverview) : .fullWindow)
    switch viewLevel {
    case .overview: root?.canvasView?.selection.map(openInFullWindow(node:))
    case .focused: setFullWindow(true)
    case .fullWindow: exitFullWindow()
    }
  }

  /// A card's Maximize control or menu item: its page straight to Full window.
  func maximize(node id: String) {
    toggles.begin(toward: .fullWindow, byKey: false)
    openInFullWindow(node: id)
  }

  /// Leaves Full window the way it was entered: a page maximized from its card shrinks back to
  /// that card in the overview, any other goes back to the focused page.
  func exitFullWindow(byKey: Bool = true) {
    let level = viewLevel.exited(maximizedFromOverview: maximizedFromOverview)
    toggles.begin(toward: level, byKey: byKey)
    if level == .overview {
      showOverview()
    } else {
      setFullWindow(false)
    }
  }

  /// The focused page takes the whole window, or gives it back. Under Reduce Motion the change is
  /// instant; otherwise the page's last look is captured first, as when leaving for the overview.
  func setFullWindow(_ fill: Bool) {
    guard presentation == .focused, fillsWindow != fill, activeTab != nil, !quitting,
      leaving == nil, filling == nil
    else { return }
    guard !motionReduced else { return commitFill(fill) }
    let id = activeTabId
    filling = Task {
      if let tab = activeTab { await previews.captureForOverview(tab) }
      guard !Task.isCancelled else { return }
      filling = nil
      guard presentation == .focused, activeTabId == id, fillsWindow != fill else { return }
      if motionReduced { commitFill(fill) } else { camera.toFill(fill) }
    }
  }

  private func commitFill(_ fill: Bool) {
    camera.cancel()
    fillsWindow = fill
    root?.settleFillChrome()
    applyPresentation()
  }

  /// A card's page, opened in Full window: from the overview a double-click or ⌘↩ on the selection.
  /// A closed page is reopened into Full window.
  func openInFullWindow(node id: String) {
    guard let node = canvas.graph.nodes.first(where: { $0.id == id }) else { return }
    guard let tabId = node.tabId, tab(id: tabId) != nil else {
      let fromOverview = presentation == .overview
      camera.toPage(of: id) {
        fillsWindow = true
        maximizedFromOverview = fromOverview
        openTab(url: node.url, title: node.title, origin: .reopen(node: node.id))
        if presentation != .focused { fillsWindow = false }
      }
      return notify("Reopened closed page")
    }
    openInFullWindow(tab: tabId)
  }

  func openInFullWindow(tab id: String) {
    guard tab(id: id) != nil else { return }
    // A page still flying in is re-aimed at the full frame, not captured: there is nothing shown yet.
    if presentation == .focused, id == activeTabId, !camera.defersFocus {
      // Already filling the window, the choice still hands the keyboard back to the page.
      return fillsWindow ? activate(id) : setFullWindow(true)
    }
    let fromOverview = presentation == .overview
    let commit = { [self] in
      fillsWindow = true
      maximizedFromOverview = fromOverview
      activate(id)
      if presentation != .focused { fillsWindow = false }
    }
    guard let node = canvas.graph.nodeId(forTab: id) else { return commit() }
    camera.toPage(of: node, commit: commit)
  }

  /// The second press of a double-click on the card a plain click just opened takes that page to
  /// Full window. True when the press is this app's.
  func claimsDoubleClick(_ event: NSEvent) -> Bool {
    guard event.window === window else { return false }
    guard event.clickCount == 2 else {
      cardClick = nil
      return false
    }
    guard let click = cardClick, viewLevel != .fullWindow,
      hypot(event.locationInWindow.x - click.point.x, event.locationInWindow.y - click.point.y) < 8
    else { return false }
    cardClick = nil
    openInFullWindow(node: click.node)
    return true
  }

  /// One level toward the overview: Full window to the focused page, the focused page to the
  /// overview.
  func stepOut() {
    if viewLevel.steppedOut == .focused {
      setFullWindow(false)
    } else {
      perform(.showOverview)
    }
  }

  /// A pinch out leaves one level per gesture, however many packets it sends. True when the
  /// pinch is this app's, so the page never sees it.
  func pinchedOut(_ event: NSEvent) -> Bool {
    defer {
      if event.phase.isEmpty || !event.phase.isDisjoint(with: [.ended, .cancelled]) {
        pinchStepped = false
      }
    }
    guard event.magnification < 0, presentation == .focused, event.window === window,
      !launcher.isOpen
    else { return false }
    if !pinchStepped {
      pinchStepped = true
      stepOut()
    }
    return true
  }

  /// A click on bare window beside the focused page leaves it for the overview.
  func emptyClicked() {
    guard presentation == .focused, !fillsWindow, !launcher.isOpen, !activity.isOpen else { return }
    showOverview()
  }

  // MARK: First-run hint

  /// One line on the first empty canvas, shown once: it is recorded the moment it appears, and a
  /// page, or a later launch, ends it for good.
  func refreshHint() {
    let empty = presentation == .overview && canvas.graph.nodes.isEmpty
    switch hintState {
    case .unseen where empty:
      hintState = .showing
      FileManager.default.createFile(atPath: dataDir.hintSeen, contents: nil)
    case .showing where !empty:
      hintState = .done
    default:
      break
    }
    root?.setHint(hintState == .showing ? Self.firstRunHint : nil)
  }
}
