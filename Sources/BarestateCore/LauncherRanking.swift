import Foundation

/// A page the launcher can offer from history, bookmarks or recents. The lowercase keys are built
/// once, so ranking thousands of them per keystroke does no string work beyond the search itself.
public struct LauncherSite: Sendable, Equatable {
  public let url: String
  public let title: String
  fileprivate let titleKey: String
  fileprivate let urlKey: String

  public init(url: String, title: String) {
    self.url = url
    self.title = title
    titleKey = title.lowercased()
    urlKey = url.lowercased()
  }
}

public struct LauncherTab: Sendable, Equatable {
  public let id: String
  public let title: String
  public let url: String

  public init(id: String, title: String, url: String) {
    self.id = id
    self.title = title
    self.url = url
  }
}

/// Everything ranking reads. Value types only, so a snapshot crosses to a background task intact.
public struct LauncherSnapshot: Sendable {
  /// Most recently used first.
  public var tabs: [LauncherTab]
  public var activeTabId: String?
  /// Newest first; ties already broken by the store.
  public var history: [LauncherSite]
  public var bookmarks: [LauncherSite]
  public var commands: BrowserCommand.Context
  public var runs: [Run]

  public init(
    tabs: [LauncherTab] = [], activeTabId: String? = nil, history: [LauncherSite] = [],
    bookmarks: [LauncherSite] = [], commands: BrowserCommand.Context = .init(), runs: [Run] = []
  ) {
    self.tabs = tabs
    self.activeTabId = activeTabId
    self.history = history
    self.bookmarks = bookmarks
    self.commands = commands
    self.runs = runs
  }
}

/// What the launcher is searching: everything, only visited pages, the open pages, or only the web.
public enum LauncherScope: String, Sendable {
  case all, history, pages, web
}

public struct LauncherRow: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case switchTab, openURL, search, startTask, history, bookmark, command, run, findWeb, retry
  }

  /// A run row shows what the run is doing; every other row is `ready`.
  public enum Status: String, Sendable {
    case ready, loading, success
  }

  public let section: String
  public let kind: Kind
  public var title: String
  public var subtitle: String
  /// What choosing the row does, in the design's words.
  public let actionLabel: String
  /// A tab id, a URL, the query text, a command name or a run id.
  public let target: String
  public var enabled = true
  public var status = Status.ready
  /// The tab a Start task row hands to its run.
  public var owner: String?

  /// Stable across re-ranking: the same thing is the same row.
  public var id: String { "\(kind.rawValue):\(target)" }
}

public struct LauncherSection: Sendable, Equatable {
  public let title: String
  public let rows: [LauncherRow]

  /// Rows that follow each other under one title form one section.
  public static func group(_ rows: [LauncherRow]) -> [LauncherSection] {
    var sections: [LauncherSection] = []
    for row in rows {
      if let last = sections.last, last.title == row.section {
        sections[sections.count - 1] = LauncherSection(title: last.title, rows: last.rows + [row])
      } else {
        sections.append(LauncherSection(title: row.section, rows: [row]))
      }
    }
    return sections
  }
}

public struct LauncherResult: Sendable {
  public let generation: Int
  public let query: String
  public let rows: [LauncherRow]
}

/// The launcher's suggestions: local and deterministic, and never a model call.
public enum LauncherRanking {
  public static let requestSection = "For this request"
  static let instructionWords = 4
  static let tabLimit = 3
  static let siteLimit = 3
  static let commandLimit = 3
  static let continueLimit = 5
  static let historyScopeLimit = 50
  static let runLimit = 2

  public static func rank(
    query: String, snapshot: LauncherSnapshot, generation: Int, scope: LauncherScope = .all
  ) -> LauncherResult {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let rows: [LauncherRow]
    switch scope {
    case .all:
      rows =
        runRows(snapshot, listing: text.isEmpty)
        + (text.isEmpty
          ? emptyRows(snapshot) : typedRows(text, snapshot))
    case .history:
      rows = historyRows(text, snapshot)
    case .pages:
      rows = pageRows(text, snapshot)
    case .web:
      rows = text.isEmpty ? [] : [searchRow(text)]
    }
    return LauncherResult(generation: generation, query: text, rows: rows)
  }

  // MARK: Result sets

  /// Stop leads every result set while a run works; run rows only list on an empty query.
  private static func runRows(_ snapshot: LauncherSnapshot, listing: Bool) -> [LauncherRow] {
    let context = context(snapshot)
    var rows: [LauncherRow] = []
    if context.activeRun != nil { rows.append(commandRow(.stopRun, context, section: "Tasks")) }
    guard listing else { return rows }
    let activity = BrowserCommand.showRunActivity.availability(in: context) == .enabled
    rows += snapshot.runs.reversed().prefix(runLimit).map {
      var row = runRow($0)
      row.enabled = activity
      return row
    }
    return rows
  }

  private static func runRow(_ run: Run) -> LauncherRow {
    var row = LauncherRow(
      section: "Tasks", kind: .run, title: run.prompt, subtitle: "Muse · \(run.state.statusLabel)",
      actionLabel: "Open the result", target: run.id)
    switch run.state {
    case .pending:
      (row.title, row.subtitle, row.status) = (
        "Connecting to Muse", "Your request is saved", .loading
      )
    case .running, .waitingApproval:
      row.status = .loading
    case .completed:
      (row.title, row.subtitle, row.status) = ("\(run.prompt) ready", "Open the result", .success)
    case .stopped, .failed:
      if let reason = run.reason, reason != run.state.statusLabel { row.subtitle += " · \(reason)" }
    }
    return row
  }

  private static func emptyRows(_ snapshot: LauncherSnapshot) -> [LauncherRow] {
    let context = context(snapshot)
    let pages = openPages(snapshot)
    var rows = pages.prefix(continueLimit).map { tabRow($0, section: "Continue") }
    if let page = activePage(snapshot) ?? pages.first {
      rows.append(
        suggestion("Summarize \(page.title)", prompt: "Summarize \(page.title)", owner: page.id))
    }
    if pages.count >= 2 {
      let named = pages.prefix(continueLimit).map(\.title).joined(separator: "; ")
      let more = pages.count > continueLimit ? " and \(pages.count - continueLimit) more" : ""
      rows.append(
        suggestion(
          "Compare the pages I have open", prompt: "Compare these open pages: \(named)\(more)",
          owner: activePage(snapshot)?.id))
    }
    rows.append(
      LauncherRow(
        section: "Suggested", kind: .findWeb, title: "Find something on the web",
        subtitle: "Web search", actionLabel: "Search the web", target: ""))
    rows += [.openPages, .history, .settings].map { commandRow($0, context) }
    if context.phoneConnected { rows.append(commandRow(.disconnectPhone, context)) }
    return rows
  }

  private static func typedRows(_ text: String, _ snapshot: LauncherSnapshot) -> [LauncherRow] {
    let context = context(snapshot)
    let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let instruction = tokens.count >= instructionWords
    var rows: [LauncherRow] = []
    if let url = AddressInput.location(text) {
      rows.append(
        LauncherRow(
          section: requestSection, kind: .openURL, title: text, subtitle: "Open website",
          actionLabel: "Open website", target: url))
      rows.append(searchRow(text))
    } else {
      let task = taskRow(text, owner: activePage(snapshot)?.id)
      let search = searchRow(text)
      rows = instruction ? [task, search] : [search, task]
    }
    let pages = openPages(snapshot)
    // A sentence rarely appears whole in a page title: its content words relate pages to it.
    let tabs = best(
      pages, instruction ? tokens.filter { $0.count >= 3 } : tokens, limit: tabLimit,
      floor: instruction ? 3 : 1, all: !instruction
    ) { ($0.title.lowercased(), $0.url.lowercased()) }
    rows += tabs.map { tabRow($0, section: "Related open pages") }
    let open = Set(pages.map(\.url))
    let bookmarks = best(
      snapshot.bookmarks, tokens, limit: siteLimit, skipping: { open.contains($0.url) },
      keys: { ($0.titleKey, $0.urlKey) })
    let marked = Set(bookmarks.map(\.url))
    let history = best(
      snapshot.history, tokens, limit: siteLimit,
      skipping: { open.contains($0.url) || marked.contains($0.url) },
      keys: { ($0.titleKey, $0.urlKey) })
    rows += history.map { siteRow($0, section: "History", kind: .history) }
    rows += bookmarks.map { siteRow($0, section: "Bookmarks", kind: .bookmark) }
    let commands = BrowserCommand.allCases.filter { $0 != .stopRun || context.activeRun == nil }
    rows += best(commands, tokens, limit: commandLimit, floor: 3) {
      ("\($0.title(in: context)) \($0.keywords)".lowercased(), "")
    }.map { commandRow($0, context) }
    return rows
  }

  /// Visited pages only, newest first, filtered by every typed word.
  private static func historyRows(_ text: String, _ snapshot: LauncherSnapshot) -> [LauncherRow] {
    let sites: [LauncherSite]
    if text.isEmpty {
      sites = Array(snapshot.history.prefix(historyScopeLimit))
    } else {
      let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
      sites = best(snapshot.history, tokens, limit: historyScopeLimit) { ($0.titleKey, $0.urlKey) }
    }
    return sites.map {
      var row = siteRow($0, section: "History", kind: .history)
      row.subtitle = host(of: $0.url)
      return row
    }
  }

  /// Every open page, most recent first, filtered by every typed word. Unlike Continue and
  /// Related open pages it has no cap: the list scrolls.
  private static func pageRows(_ text: String, _ snapshot: LauncherSnapshot) -> [LauncherRow] {
    let open = openPages(snapshot)
    let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let pages =
      text.isEmpty
      ? open : best(open, tokens, limit: .max) { ($0.title.lowercased(), $0.url.lowercased()) }
    return pages.map {
      var row = tabRow($0, section: "Open pages")
      row.subtitle = host(of: $0.url)
      return row
    }
  }

  // MARK: Pieces

  private static func context(_ snapshot: LauncherSnapshot) -> BrowserCommand.Context {
    var context = snapshot.commands
    context.activeRun = snapshot.runs.last { $0.state.isInProgress }
    context.hasRuns = !snapshot.runs.isEmpty
    return context
  }

  /// Tabs worth switching to: a blank tab has nothing to go back to.
  private static func openPages(_ snapshot: LauncherSnapshot) -> [LauncherTab] {
    snapshot.tabs.filter { !AddressInput.isBlank($0.url) }
  }

  private static func activePage(_ snapshot: LauncherSnapshot) -> LauncherTab? {
    openPages(snapshot).first { $0.id == snapshot.activeTabId }
  }

  /// Items whose title and address hold every word, best first. The sort is stable on the order
  /// the caller already gave (tab order, newest first), so ties never shuffle.
  private static func best<Item>(
    _ items: [Item], _ tokens: [String], limit: Int,
    skipping skipped: (Item) -> Bool = { _ in false }, floor: Int = 1, all: Bool = true,
    keys: (Item) -> (title: String, url: String)
  ) -> [Item] {
    let needles = tokens.map { Array($0.utf8) }
    var scored: [(score: Int, index: Int)] = []
    for (index, item) in items.enumerated() {
      if skipped(item) { continue }
      let (title, url) = keys(item)
      let total = score(needles, title: title, url: url, floor: floor, all: all)
      if total > 0 { scored.append((total, index)) }
    }
    scored.sort { ($0.score, $1.index) > ($1.score, $0.index) }
    return scored.prefix(limit).map { items[$0.index] }
  }

  private static func score(
    _ needles: [[UInt8]], title: String, url: String, floor: Int, all: Bool
  ) -> Int {
    var title = title
    var url = url
    return title.withUTF8 { titleBytes in
      url.withUTF8 { urlBytes in
        var total = 0
        for needle in needles {
          let each = score(needle, title: titleBytes, url: urlBytes)
          if each < floor {
            if all { return 0 }
            continue
          }
          total += each
        }
        return total
      }
    }
  }

  /// Title prefix 4, a word of the title 3, anywhere in the title 2, in the address 1.
  private static func score(
    _ needle: [UInt8], title: UnsafeBufferPointer<UInt8>, url: UnsafeBufferPointer<UInt8>
  ) -> Int {
    guard !needle.isEmpty else { return 0 }
    var found: Int?
    var wordStart = false
    var from = 0
    while let at = firstIndex(of: needle, in: title, from: from) {
      if at == 0 { return 4 }
      if found == nil { found = at }
      if title[at - 1] == UInt8(ascii: " ") {
        wordStart = true
        break
      }
      from = at + 1
    }
    if wordStart { return 3 }
    if found != nil { return 2 }
    return firstIndex(of: needle, in: url, from: 0) != nil ? 1 : 0
  }

  private static func firstIndex(
    of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from start: Int
  ) -> Int? {
    let last = haystack.count - needle.count
    guard last >= start else { return nil }
    let first = needle[0]
    var index = start
    while index <= last {
      if haystack[index] == first {
        var offset = 1
        while offset < needle.count && haystack[index + offset] == needle[offset] { offset += 1 }
        if offset == needle.count { return index }
      }
      index += 1
    }
    return nil
  }

  private static func tabRow(_ tab: LauncherTab, section: String) -> LauncherRow {
    LauncherRow(
      section: section, kind: .switchTab, title: tab.title.isEmpty ? tab.url : tab.title,
      subtitle: "Switch to open page", actionLabel: "Switch to open page", target: tab.id)
  }

  private static func siteRow(_ site: LauncherSite, section: String, kind: LauncherRow.Kind)
    -> LauncherRow
  {
    LauncherRow(
      section: section, kind: kind, title: site.title.isEmpty ? host(of: site.url) : site.title,
      subtitle: "Open website", actionLabel: "Open website", target: site.url)
  }

  private static func searchRow(_ query: String) -> LauncherRow {
    LauncherRow(
      section: requestSection, kind: .search, title: "Search the web",
      subtitle: "See search results for this request", actionLabel: "Search the web",
      target: query)
  }

  private static func taskRow(_ prompt: String, owner: String?) -> LauncherRow {
    var row = LauncherRow(
      section: requestSection, kind: .startTask, title: "Start task",
      subtitle: "Start a task with Muse", actionLabel: "Start task", target: prompt)
    row.owner = owner
    return row
  }

  private static func suggestion(_ title: String, prompt: String, owner: String?) -> LauncherRow {
    var row = LauncherRow(
      section: "Suggested", kind: .startTask, title: title, subtitle: "Start a task with Muse",
      actionLabel: "Start task", target: prompt)
    row.owner = owner
    return row
  }

  private static func commandRow(
    _ command: BrowserCommand, _ context: BrowserCommand.Context, section: String = "Browser"
  ) -> LauncherRow {
    var row = LauncherRow(
      section: section, kind: .command, title: command.title(in: context),
      subtitle: command.subtitle, actionLabel: command.title(in: context),
      target: command.rawValue)
    if case .disabled(let reason) = command.availability(in: context) {
      row.enabled = false
      row.subtitle = reason
    }
    return row
  }

  private static func host(of url: String) -> String {
    URL(string: url)?.host() ?? url
  }
}
