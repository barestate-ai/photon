import BarestateCore
import Testing

struct LauncherRankingTests {
  private func snapshot(
    tabs: [(String, String)] = [], active: String? = nil, history: [(String, String)] = [],
    bookmarks: [(String, String)] = [], commands: BrowserCommand.Context = .init()
  ) -> LauncherSnapshot {
    LauncherSnapshot(
      tabs: tabs.enumerated().map {
        LauncherTab(id: "t\($0.offset + 1)", title: $0.element.0, url: $0.element.1)
      },
      activeTabId: active ?? (tabs.isEmpty ? nil : "t1"),
      history: history.map { LauncherSite(url: $0.0, title: $0.1) },
      bookmarks: bookmarks.map { LauncherSite(url: $0.0, title: $0.1) }, commands: commands)
  }

  private func rank(
    _ query: String, _ snapshot: LauncherSnapshot = LauncherSnapshot(),
    scope: LauncherScope = .all
  ) -> [LauncherRow] {
    LauncherRanking.rank(query: query, snapshot: snapshot, generation: 1, scope: scope).rows
  }

  private func shape(_ rows: [LauncherRow]) -> [String] {
    LauncherSection.group(rows).map {
      "\($0.title): " + $0.rows.map(\.title).joined(separator: " | ")
    }
  }

  private let trips = [
    ("Kyoto trip", "http://127.0.0.1:47810/a.html"),
    ("Places to stay", "http://127.0.0.1:47810/b.html"),
    ("Weekend reading", "http://127.0.0.1:47810/c.html"),
  ]

  private let instruction = "Find a quiet hotel in Kyoto under $200 a night"

  // MARK: Empty query

  @Test func emptyQueryHasContinueSuggestedAndBrowserFromTheOpenPages() {
    let data = snapshot(tabs: [
      ("Kyoto hotel comparison", "http://a.test/1"), ("Kyoto map", "http://a.test/2"),
      ("Trip notes", "http://a.test/3"),
    ])
    let rows = rank("", data)
    #expect(
      shape(rows) == [
        "Continue: Kyoto hotel comparison | Kyoto map | Trip notes",
        "Suggested: Summarize Kyoto hotel comparison | Compare the pages I have open"
          + " | Find something on the web",
        "Browser: Open pages | History | Settings",
      ])
    #expect(rows.prefix(3).allSatisfy { $0.subtitle == "Switch to open page" })
    #expect(rows[3...4].allSatisfy { $0.subtitle == "Start a task with Muse" })
    #expect(rows[5].subtitle == "Web search")
    #expect(
      rows.map(\.subtitle).suffix(3) == [
        "Switch to any open page", "Find a page you visited", "Manage browser preferences",
      ])
  }

  @Test func suggestionsOwnTheirPage() {
    let data = snapshot(tabs: [("A", "http://a.test/1"), ("B", "http://a.test/2")], active: "t2")
    let tasks = rank("", data).filter { $0.kind == .startTask }
    #expect(tasks.map(\.owner) == ["t2", "t2"])
    #expect(tasks[0].target == "Summarize B")
    #expect(tasks[1].target == "Compare these open pages: A; B")
  }

  @Test func comparingNamesFiveAndCountsTheRest() {
    let tabs = (1...7).map { ("Page \($0)", "http://a.test/\($0)") }
    let compare = rank("", snapshot(tabs: tabs)).first { $0.title.hasPrefix("Compare") }
    #expect(
      compare?.target
        == "Compare these open pages: Page 1; Page 2; Page 3; Page 4; Page 5 and 2 more")
    #expect(rank("", snapshot(tabs: tabs)).filter { $0.section == "Continue" }.count == 5)
  }

  @Test func oneOrNoPagesDropTheirSuggestions() {
    let one = rank("", snapshot(tabs: [("Only", "http://a.test/1")]))
    #expect(
      shape(one) == [
        "Continue: Only", "Suggested: Summarize Only | Find something on the web",
        "Browser: Open pages | History | Settings",
      ])
    let none = rank("", snapshot(tabs: [("New tab", "about:blank")]))
    #expect(
      shape(none) == [
        "Suggested: Find something on the web", "Browser: Open pages | History | Settings",
      ])
  }

  @Test func theSameInputGivesTheSameRowsAndNoRowIsATaskWithoutAnExplicitCommit() {
    let data = snapshot(tabs: trips)
    #expect(rank("", data) == rank("", data))
    #expect(rank("   ", data).map(\.id) == rank("", data).map(\.id))
  }

  // MARK: Typed text

  @Test func addressesPutOpenWebsiteFirstWithANormalizedTarget() {
    let cases = [
      ("example.com", "https://example.com"),
      ("https://example.com/a", "https://example.com/a"),
      ("localhost:47810", "http://localhost:47810"),
      ("127.0.0.1:47810/x.html", "http://127.0.0.1:47810/x.html"),
    ]
    for (typed, target) in cases {
      let rows = rank(typed)
      #expect(rows.first?.kind == .openURL, "\(typed)")
      #expect(rows.first?.target == target, "\(typed)")
      #expect(rows.first?.title == typed)
      #expect(rows.first?.subtitle == "Open website")
      #expect(!rows.contains { $0.kind == .startTask }, "\(typed)")
    }
  }

  @Test func aScriptSchemeIsNotAnAddress() {
    #expect(rank("javascript:alert(1)").first?.kind == .search)
  }

  @Test func shortTextSearchesFirstThenOffersATask() {
    let rows = rank("kyoto hotels")
    #expect(rows.map(\.kind) == [.search, .startTask])
    #expect(rows[0].target == "kyoto hotels")
    #expect(rows[0].subtitle == "See search results for this request")
    #expect(rows[1].title == "Start task")
    #expect(rows[1].subtitle == "Start a task with Muse")
  }

  @Test func anInstructionOfFourWordsStartsATaskFirstThenRelatedPages() {
    let data = snapshot(tabs: [
      ("Kyoto hotel comparison", "http://a.test/1"), ("Other", "http://a.test/2"),
    ])
    let rows = rank(instruction, data)
    #expect(rows.map(\.kind) == [.startTask, .search, .switchTab])
    #expect(rows.map(\.title) == ["Start task", "Search the web", "Kyoto hotel comparison"])
    #expect(rows[0].target == instruction)
    #expect(rows[0].owner == "t1")
    #expect(rank("one two three four").map(\.kind) == [.startTask, .search])
    #expect(rank("one two three").map(\.kind) == [.search, .startTask])
    let related = rank("Find a quiet hotel in Kyoto", data)
    #expect(
      related.map(\.section) == [
        "For this request", "For this request", "Related open pages",
      ])
  }

  @Test func startTaskPassesNoPageWhenThereIsNone() {
    #expect(rank(instruction).first?.owner == nil)
    let blank = snapshot(tabs: [("New tab", "about:blank")])
    #expect(rank(instruction, blank).first?.owner == nil)
    #expect(rank(instruction, snapshot(tabs: trips)).first?.owner == "t1")
  }

  @Test func matchesComeFromPagesHistoryAndBookmarksAfterTheRequest() {
    let data = snapshot(
      tabs: trips, history: [("https://kyoto.example.org/guide", "Guide to Kyoto")],
      bookmarks: [("https://kyoto.example.net/", "Kyoto food")])
    let rows = rank("kyoto", data)
    #expect(rows.map(\.kind) == [.search, .startTask, .switchTab, .history, .bookmark])
    #expect(
      rows.map(\.subtitle).suffix(3) == ["Switch to open page", "Open website", "Open website"])
    #expect(rows[2].target == "t1")
    #expect(rows[3].target == "https://kyoto.example.org/guide")
  }

  @Test func everyWordMustMatchAndTypingFiltersTheRows() {
    let data = snapshot(tabs: trips)
    #expect(rank("k", data).contains { $0.title == "Kyoto trip" })
    #expect(rank("kyo", data).contains { $0.title == "Kyoto trip" })
    #expect(!rank("kyo", data).contains { $0.title == "Places to stay" })
    #expect(!rank("kyoto hotels", data).contains { $0.kind == .switchTab })
    #expect(rank("trip kyo", data).contains { $0.title == "Kyoto trip" })
  }

  @Test func aPageHidesItsOwnHistoryAndBookmarkRows() {
    let data = snapshot(
      tabs: [("Kyoto trip", "http://a.test/1")], history: [("http://a.test/1", "Kyoto trip")],
      bookmarks: [("http://a.test/1", "Kyoto trip")])
    #expect(rank("kyoto", data).map(\.kind) == [.search, .startTask, .switchTab])
  }

  @Test func betterMatchesRankFirstAndTiesKeepListOrder() {
    let data = snapshot(
      tabs: [
        ("Hotels in Kyoto", "https://a.test/"), ("Kyoto hotels", "https://b.test/"),
        ("Kyoto stays", "https://c.test/"), ("Kyoto guide", "https://d.test/"),
      ])
    let titles = rank("kyoto", data).filter { $0.kind == .switchTab }.prefix(3).map(\.title)
    #expect(titles == ["Kyoto hotels", "Kyoto stays", "Kyoto guide"])
  }

  @Test func rankingIsDeterministic() {
    let data = snapshot(
      tabs: trips,
      history: (0..<40).map { ("https://site\($0).example.com/", "Kyoto page \($0 % 3)") },
      bookmarks: (0..<10).map { ("https://mark\($0).example.com/", "Kyoto mark") })
    for query in ["k", "ky", "kyoto", "kyoto page", "example.com", "find a hotel in kyoto", "re"] {
      let first = rank(query, data).map(\.id)
      for _ in 0..<5 { #expect(rank(query, data).map(\.id) == first) }
    }
  }

  @Test func resultsCarryTheirGenerationAndQuery() {
    let result = LauncherRanking.rank(query: " kyo ", snapshot: LauncherSnapshot(), generation: 7)
    #expect(result.generation == 7)
    #expect(result.query == "kyo")
  }

  @Test func rowIdentityIsKindPlusTarget() {
    let rows = rank("kyoto hotels")
    #expect(rows.map(\.id) == ["search:kyoto hotels", "startTask:kyoto hotels"])
  }

  // MARK: Commands

  @Test func aCommandTitleSurfacesItsRow() {
    var context = BrowserCommand.Context()
    context.hasPage = true
    let data = snapshot(tabs: trips, commands: context)
    let reload = rank("reload", data).first { $0.kind == .command }
    #expect(reload?.id == "command:reload")
    #expect(reload?.enabled == true)
    #expect(reload?.section == "Browser")
    #expect(rank("history", data).contains { $0.id == "command:history" })
    #expect(rank("sett", data).contains { $0.id == "command:settings" })
    #expect(rank("refresh", data).contains { $0.id == "command:reload" })
    #expect(rank("preferences", data).contains { $0.id == "command:settings" })
  }

  @Test func anImpossibleCommandIsDisabledAndSaysWhy() {
    for typed in ["reload", "back", "forward", "close", "find", "reopen"] {
      let rows = rank(typed).filter { $0.kind == .command }
      #expect(!rows.isEmpty, "\(typed)")
      for row in rows where !row.enabled { #expect(!row.subtitle.isEmpty, "\(typed)") }
    }
    let stop = rank("stop").first { $0.id == "command:stopRun" }
    #expect(stop?.enabled == false)
    #expect(stop?.subtitle == "No task is running")
    #expect(rank("zoom in").first { $0.id == "command:zoomIn" }?.enabled == false)
  }

  @Test func disconnectPhoneIsFoundByNameAndListedOnlyWhileAPhoneIsConnected() {
    let idle = rank("disconnect phone", snapshot(tabs: trips)).first {
      $0.id == "command:disconnectPhone"
    }
    #expect(idle?.enabled == false)
    #expect(idle?.subtitle == "No phone is connected")
    #expect(!rank("", snapshot(tabs: trips)).contains { $0.id == "command:disconnectPhone" })

    var connected = snapshot(tabs: trips)
    connected.commands.phoneConnected = true
    let typed = rank("disconnect", connected).first { $0.id == "command:disconnectPhone" }
    #expect(typed?.enabled == true)
    let listed = rank("", connected).first { $0.id == "command:disconnectPhone" }
    #expect(listed?.title == "Disconnect phone")
    #expect(listed?.enabled == true)
  }

  @Test func plainWordsDoNotMatchInsideACommandsTitle() {
    #expect(!rank("ack").contains { $0.kind == .command })
  }

  // MARK: History scope

  @Test func historyScopeListsOnlyVisitedPagesNewestFirstAndFiltersThem() {
    let data = snapshot(
      tabs: trips,
      history: [
        ("https://news.example.com/a", "News"), ("https://kyoto.example.org/", "Kyoto guide"),
        ("https://kyoto.example.net/", "Kyoto food"),
      ], bookmarks: [("https://mark.example.com/", "Marked")])
    let all = rank("", data, scope: .history)
    #expect(all.allSatisfy { $0.kind == .history && $0.section == "History" })
    #expect(all.map(\.title) == ["News", "Kyoto guide", "Kyoto food"])
    #expect(all.map(\.subtitle) == ["news.example.com", "kyoto.example.org", "kyoto.example.net"])
    #expect(rank("kyoto", data, scope: .history).map(\.title) == ["Kyoto guide", "Kyoto food"])
    #expect(rank("zzz", data, scope: .history).isEmpty)
  }

  // MARK: Open pages scope

  private func pages(_ count: Int) -> [(String, String)] {
    (1...count).map { ("Page \($0)", "http://a.test/p\($0).html") }
  }

  @Test func pagesScopeListsEveryNonBlankPageInRecencyOrderWithItsHost() {
    let data = snapshot(
      tabs: pages(7) + [("New tab", "about:blank")],
      history: [("https://old.example.com/", "Old")], bookmarks: [("https://m.example.com/", "M")])
    let rows = rank("", data, scope: .pages)
    #expect(rows.map(\.title) == (1...7).map { "Page \($0)" })
    #expect(rows.allSatisfy { $0.kind == .switchTab && $0.section == "Open pages" })
    #expect(rows.allSatisfy { $0.subtitle == "a.test" })
    #expect(rows.map(\.target) == (1...7).map { "t\($0)" })
    #expect(rank("", snapshot(tabs: [("New tab", "about:blank")]), scope: .pages).isEmpty)
  }

  @Test func pagesScopeIsNotCappedLikeContinueOrRelatedPages() {
    let data = snapshot(tabs: pages(60))
    #expect(rank("", data, scope: .pages).count == 60)
    #expect(rank("page", data, scope: .pages).count == 60)
  }

  @Test func pagesScopeFiltersByTitleOrAddressIgnoringCaseAndNeverAsksTheNetwork() {
    let data = snapshot(tabs: [
      ("Kyoto trip", "http://a.test/alpha.html"), ("Places to stay", "http://a.test/beta.html"),
      ("Weekend reading", "http://a.test/gamma.html"),
    ])
    #expect(rank("KYOTO", data, scope: .pages).map(\.title) == ["Kyoto trip"])
    #expect(rank("beta", data, scope: .pages).map(\.title) == ["Places to stay"])
    #expect(rank("a.test", data, scope: .pages).count == 3)
    #expect(rank("stay beta", data, scope: .pages).map(\.title) == ["Places to stay"])
    #expect(rank("zzz", data, scope: .pages).isEmpty)
    #expect(rank("kyoto", data, scope: .pages).allSatisfy { $0.kind == .switchTab })
  }

  @Test func aBlankQueryInThePagesScopeListsEveryPageAndTheEntryIsFoundByName() {
    let data = snapshot(tabs: pages(3))
    #expect(rank("  ", data, scope: .pages).count == 3)
    for word in ["open pages", "switch"] {
      let entry = rank(word, data).first { $0.id == "command:openPages" }
      #expect(entry?.title == "Open pages", "\(word)")
    }
  }

  @Test func webScopeOffersOnlyTheSearch() {
    #expect(rank("", scope: .web).isEmpty)
    let rows = rank("kyoto hotels", scope: .web)
    #expect(rows.map(\.kind) == [.search])
    #expect(rows[0].target == "kyoto hotels")
    #expect(rank("example.com", scope: .web).map(\.kind) == [.search])
  }

  // MARK: Runs

  private func run(_ state: RunState, reason: String? = nil) -> Run {
    var book = RunBook()
    var run = book.start(prompt: "Compare stays", origin: .mac, ownerTabId: nil)!
    run.state = state
    run.reason = reason
    return run
  }

  private func withRuns(_ runs: [Run]) -> LauncherSnapshot {
    var data = snapshot(tabs: trips)
    data.runs = runs
    data.commands.activityView = true
    return data
  }

  @Test func anActiveRunPutsStopFirstInEveryResultSet() {
    for state in [RunState.pending, .running, .waitingApproval] {
      let data = withRuns([run(state)])
      #expect(rank("", data).first?.title == "Stop Compare stays", "\(state)")
      #expect(rank("kyoto", data).first?.id == "command:stopRun", "\(state)")
      #expect(rank("kyoto", data).first?.enabled == true)
    }
    for state in [RunState.stopped, .failed, .completed] {
      #expect(!rank("", withRuns([run(state)])).contains { $0.id == "command:stopRun" })
    }
  }

  @Test func eachRunStateHasItsOwnRow() {
    func row(_ state: RunState, _ reason: String? = nil) -> LauncherRow? {
      rank("", withRuns([run(state, reason: reason)])).first { $0.kind == .run }
    }
    #expect(row(.pending)?.title == "Connecting to Muse")
    #expect(row(.pending)?.subtitle == "Your request is saved")
    #expect(row(.pending)?.status == .loading)
    #expect(row(.running)?.subtitle == "Muse · working")
    #expect(row(.running)?.status == .loading)
    #expect(row(.waitingApproval)?.subtitle == "Muse · waiting for approval")
    #expect(row(.stopped, "taken-over")?.subtitle == "Muse · stopped · taken-over")
    #expect(row(.stopped, "stopped")?.subtitle == "Muse · stopped")
    #expect(
      row(.failed, "needs-human")?.subtitle == "Muse · failed · The task could not be finished.")
    #expect(
      row(.failed, "run-cap")?.subtitle == "Muse · failed · The task reached its spending limit.")
    #expect(row(.failed)?.status == .ready)
    #expect(row(.running)?.title == "Compare stays")
    let done = row(.completed)
    #expect(done?.title == "Compare stays ready")
    #expect(done?.subtitle == "Open the result")
    #expect(done?.status == .success)
    #expect(done?.enabled == true)
  }

  @Test func aCompletedRunWithAnAnswerShowsItsStartOnOneLineInTheRow() {
    var answered = run(.completed)
    answered.answer = "Kyoto is older.\n\nTokyo is   bigger."
    func completed(_ run: Run) -> LauncherRow? {
      rank("", withRuns([run])).first { $0.kind == .run }
    }
    #expect(completed(answered)?.subtitle == "Kyoto is older. Tokyo is bigger.")
    #expect(completed(answered)?.title == "Compare stays ready")
    #expect(completed(answered)?.actionLabel == "Open the result")
    answered.answer = String(repeating: "word ", count: 80)
    let long = completed(answered)?.subtitle ?? ""
    #expect(long.count == 141 && long.hasSuffix("…"))
    #expect(completed(run(.completed))?.subtitle == "Open the result")
  }

  @Test func runRowsListOnlyForAnEmptyQueryNewestFirstAndOpenTheirOwnRun() {
    var book = RunBook()
    var first = book.start(prompt: "One", origin: .mac, ownerTabId: nil)!
    first.state = .failed
    let second = book.start(prompt: "Two", origin: .mac, ownerTabId: nil)!
    let data = withRuns([first, second])
    #expect(rank("", data).filter { $0.kind == .run }.map(\.target) == ["r2", "r1"])
    #expect(!rank("kyoto", data).contains { $0.kind == .run })
  }

  @Test func aRunRowIsDisabledUntilTheActivityViewExists() {
    var data = withRuns([run(.completed)])
    data.commands.activityView = false
    #expect(rank("", data).first { $0.kind == .run }?.enabled == false)
  }
}
