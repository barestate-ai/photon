import AppKit
import BarestateCore
import CEFBridge

/// Drives the ⌘T launcher: what is typed, what ranks, and the one action a choice runs. The
/// model decides the rows; this class gathers local data, ranks off the main thread and only
/// lets a result for the newest generation reach the panel.
@MainActor
final class LauncherController {
  private unowned let app: AppController
  private(set) var model = LauncherModel()
  private(set) var isOpen = false
  /// Whether Open website would load in the current page (⌘L) instead of a new one.
  var navigatesCurrentTab: Bool { location != nil }
  private var snapshot = LauncherSnapshot()
  private weak var returnTo: NSResponder?
  /// The field editor is released when editing ends, so its text field is kept instead.
  private weak var returnField: NSTextField?
  private var storeDirty = true
  private var loadToken = 0
  private var outageAnnounced = false
  /// Set by ⌘L: the tab whose address the field started with, so Open website navigates it.
  private var location: (tabId: String, url: String)?
  private var startedAt: [Int: UInt64] = [:]
  /// Milliseconds from the key event to a laid-out panel, for `scripts/bench.py launcher`.
  private(set) var openTimes: [Double] = []
  private(set) var updateTimes: [Double] = []

  static let historyLimit = 50_000

  init(app: AppController) {
    self.app = app
  }

  private var view: LauncherView? { app.root?.launcher }

  func wire(_ view: LauncherView) {
    view.onQuery = { [weak self] in self?.queryChanged($0) }
    view.onMove = { [weak self] in self?.move($0) }
    view.onChoose = { [weak self] in self?.commit($0) }
    view.onFocusRow = { [weak self] in self?.focusRow($0) }
    view.onDismiss = { [weak self] in self?.dismiss() }
    app.viewsById["launcherField"] = view.field
    app.viewsById["launcherPanel"] = view.panel
  }

  // MARK: Opening and closing

  /// ⌘L passes `location`: the field starts with the current page's address, selected, and a
  /// chosen address loads in that page instead of a new one.
  func open(location wantsLocation: Bool = false) {
    guard let view, let window = app.window, let root = app.root else { return }
    let began = keyStamp ?? Self.now
    if isOpen {
      view.focusField()
      return
    }
    app.activity.close()
    returnTo = window.firstResponder
    returnField = (returnTo as? NSText)?.delegate as? NSTextField
    isOpen = true
    Log.debug(.launcher, "open")
    if wantsLocation, let tab = app.activeTab, !AddressInput.isBlank(tab.url) {
      location = (tab.id, tab.url)
      _ = model.setQuery(tab.url)
    }
    view.setOrigin(app.activeTab?.caption)
    root.setCommandButtonCompact(true)
    app.refreshApproval(animated: false)
    _ = refreshState()
    model.setTaskUnavailable(app.modelOffline)
    let generation = model.reopen()
    model.apply(rank(generation))
    view.setScope(model.scope)
    view.show(query: model.query)
    render()
    view.focusField(selectAll: location != nil)
    openTimes.append(Double(Self.now - began) / 1e6)
    if storeDirty { Task { await reload() } }
  }

  /// Opens the launcher on a scope of its own with an empty field: History, open pages or web search.
  func showScope(_ scope: LauncherScope) {
    open()
    guard let view, isOpen else { return }
    let generation = model.setScope(scope)
    view.setScope(scope)
    view.show(query: "")
    model.apply(rank(generation))
    render()
    view.focusField()
  }

  func close(committed: Bool) {
    guard isOpen, let view else { return }
    isOpen = false
    Log.debug(.launcher, "close committed=\(committed)")
    startedAt.removeAll()
    // An address nobody edited is not unfinished input.
    let consumed = committed || (location.map { $0.url == model.query } ?? false)
    location = nil
    model.close(committed: consumed)
    app.window?.makeFirstResponder(nil)
    view.hide()
    app.root?.setCommandButtonCompact(false)
    app.refreshApproval()
    if consumed { view.field.stringValue = "" }
  }

  /// Escape and a click outside: the page or the control that had focus gets it back, and an
  /// unfinished query stays for the next open.
  func dismiss() {
    close(committed: false)
    restoreFocus()
  }

  private func restoreFocus() {
    guard let window = app.window else { return }
    let saved = returnTo
    let field = returnField
    returnTo = nil
    returnField = nil
    if let field {
      window.makeFirstResponder(field)
    } else if let view = saved as? NSView,
      let tab = BarestateApplication.tabId(containing: view).flatMap({ app.tab(id: $0) })
    {
      app.pageFocus(tab)
    } else if let responder = saved, responder !== window,
      window.makeFirstResponder(responder)
    {
      return
    } else if let tab = app.activeTab {
      app.pageFocus(tab)
    }
  }

  // MARK: Typing and ranking

  private func queryChanged(_ text: String) {
    guard isOpen else { return }
    let generation = model.setQuery(text)
    startedAt[generation] = keyStamp ?? Self.now
    requestRank(generation)
  }

  private func requestRank(_ generation: Int) {
    let (query, scope, snapshot) = (model.query, model.scope, snapshot)
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = LauncherRanking.rank(
        query: query, snapshot: snapshot, generation: generation, scope: scope)
      await self?.received(result)
    }
  }

  private func rank(_ generation: Int) -> LauncherResult {
    LauncherRanking.rank(
      query: model.query, snapshot: snapshot, generation: generation, scope: model.scope)
  }

  private func received(_ result: LauncherResult) {
    let before = model.activeId
    let sameQuery = model.rankedQuery == result.query
    guard isOpen, model.apply(result) else { return }
    render()
    if sameQuery, before != nil, model.activeId != before, let row = model.activeRow {
      app.announce("Selected \(row.title)")
    }
    if let began = startedAt.removeValue(forKey: result.generation) {
      updateTimes.append(Double(Self.now - began) / 1e6)
    }
  }

  /// The data behind the same query changed. The active row keeps its identity, so a late
  /// arrival never changes what Return does.
  private func refreshRanking() {
    guard isOpen else { return }
    requestRank(model.refresh())
  }

  func tabsChanged() {
    guard isOpen else { return }
    view?.setOrigin(app.activeTab?.caption)
    if refreshState() { refreshRanking() }
  }

  func storeChanged() {
    storeDirty = true
    if isOpen { Task { await reload() } }
  }

  /// History and bookmarks come from SQLite off the main thread; only the finished
  /// value types come back.
  func reload() async {
    guard let store = app.database() else { return }
    loadToken += 1
    let token = loadToken
    storeDirty = false
    let (history, bookmarks) = await Task.detached {
      let history = await store.recentSites(limit: Self.historyLimit).map {
        LauncherSite(url: $0.url, title: $0.title)
      }
      let bookmarks = await store.allBookmarks().map { LauncherSite(url: $0.url, title: $0.title) }
      return (history, bookmarks)
    }.value
    guard token == loadToken else { return }
    snapshot.history = history
    snapshot.bookmarks = bookmarks
    refreshRanking()
  }

  /// Refreshes what ranking reads from the live app; true when any of it changed.
  private func refreshState() -> Bool {
    let tabs = app.tabStore.order.recency.compactMap { app.tab(id: $0) }.map {
      LauncherTab(id: $0.id, title: app.displayTitle($0), url: $0.url)
    }
    let runs = app.runs.runs
    let (active, commands) = (app.activeTabId, app.commandContext())
    let changed =
      tabs != snapshot.tabs || active != snapshot.activeTabId || commands != snapshot.commands
      || runs != snapshot.runs
    (snapshot.tabs, snapshot.activeTabId, snapshot.commands, snapshot.runs) =
      (tabs, active, commands, runs)
    return changed
  }

  // MARK: Rows

  private func render() {
    let rows = model.rows
    view?.render(rows: rows, activeId: model.activeId, pageIncluded: passesPage(model.activeRow))
    if !outageAnnounced, rows.contains(where: { $0.kind == .retry }) {
      outageAnnounced = true
      app.announce("Unable to connect to Muse")
    }
  }

  /// Only a typed Start task row hands the page it was ranked with to its run.
  private func passesPage(_ row: LauncherRow?) -> Bool {
    guard let row, row.kind == .startTask, row.enabled, !model.query.isEmpty,
      let owner = row.owner
    else { return false }
    return owner == app.activeTabId
  }

  /// What the field says is what the rows must answer before a choice is made from them.
  private func settle() {
    if !model.isCurrent { model.apply(rank(model.generation)) }
  }

  private func move(_ step: Int) {
    settle()
    model.moveActive(by: step)
    render()
  }

  private func focusRow(_ id: String) {
    guard model.activeId != id else { return }
    model.activate(id)
    render()
  }

  /// The recovery state is latched: Muse coming back does not clear it under the typist's hands,
  /// only Retry does, and a Retry while Muse is still down changes nothing.
  func availabilityChanged() {
    if !app.modelOffline, !isOpen || !model.taskUnavailable { outageAnnounced = false }
    guard isOpen, app.modelOffline else { return }
    model.setTaskUnavailable(true)
    render()
  }

  /// Start task found Muse unavailable: the same state as an outage announced while open.
  private func showUnavailable() {
    if !model.taskUnavailable { outageAnnounced = false }
    model.setTaskUnavailable(true)
    render()
  }

  /// Clears the state only when the app finds the key, the network and the provider all there.
  private func retry() {
    guard !app.modelOffline else { return }
    Task {
      guard await app.retryMuse(), isOpen else { return }
      outageAnnounced = false
      model.setTaskUnavailable(false)
      render()
    }
  }

  /// Runs the chosen row, or the active one, exactly once: the launcher closes first, so a
  /// second Return finds nothing to run.
  private func commit(_ id: String?) {
    guard isOpen else { return }
    settle()
    let chosen = id == nil ? model.activeRow : model.rows.first { $0.id == id }
    guard let row = chosen, row.enabled else { return }
    switch row.kind {
    case .retry: return retry()
    case .startTask where app.museOutage != nil: return showUnavailable()
    case .findWeb: return showScope(.web)
    case .command where row.target == BrowserCommand.history.rawValue: return showScope(.history)
    case .command where row.target == BrowserCommand.openPages.rawValue: return showScope(.pages)
    default: break
    }
    Log.info(.launcher, "commit kind=\(row.kind)")
    let (location, scope) = (location, model.scope)
    close(committed: true)
    switch row.kind {
    case .switchTab:
      if scope == .pages { app.openInFullWindow(tab: row.target) } else { app.activate(row.target) }
    case .openURL:
      go(row.target, location, edge: .navigatedFrom)
    case .history, .bookmark:
      go(row.target, location)
    case .search:
      go(
        AddressInput.searchURL(row.target, template: app.settings.searchEngine), location,
        edge: .navigatedFrom)
    case .startTask:
      _ = app.runs.start(
        prompt: row.target, origin: .mac, tabId: row.owner.flatMap { app.tab(id: $0) }?.id)
      restoreFocus()
    case .command:
      restoreFocus()
      BrowserCommand(rawValue: row.target).map(app.perform)
    case .run:
      restoreFocus()
      app.activity.open(row.target)
    case .findWeb, .retry:
      break
    }
  }

  /// `edge` is the trail kind to record from the focused page when this opens a new page.
  private func go(_ url: String, _ location: (tabId: String, url: String)?, edge: EdgeKind? = nil) {
    if let location {
      app.navigate(tab: location.tabId, to: url)
    } else {
      app.openTab(url: url, origin: edge.map(app.focusedPageOrigin) ?? .none)
    }
  }

  // MARK: Shortcuts

  /// While the panel is open only these menu commands work; everything else is consumed.
  func allows(_ action: Selector, target: AnyObject?) -> Bool {
    if target === NSApp { return true }
    if action == #selector(AppController.closeActiveTab), app.frontAuxiliaryWindow != nil {
      return true
    }
    return [
      #selector(AppController.newTab), #selector(AppController.showSettings),
      #selector(AppController.undoEdit),
      #selector(AppController.redoEdit), #selector(AppController.cutEdit),
      #selector(AppController.copyEdit), #selector(AppController.pasteEdit),
      #selector(AppController.selectAllEdit),
    ].contains(action)
  }

  // MARK: Timing

  private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

  /// When the key event that caused this work reached `sendEvent`, if it was recent.
  private var keyStamp: UInt64? {
    guard let stamp = (NSApp as? BarestateApplication)?.keyDownAt, Self.now - stamp < 1_000_000_000
    else { return nil }
    return stamp
  }

  func resetTimes() {
    openTimes = []
    updateTimes = []
  }
}
