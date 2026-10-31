import BarestateCore
import Testing

struct LauncherModelTests {
  private let data = LauncherSnapshot(
    tabs: [
      LauncherTab(id: "t1", title: "Kyoto trip", url: "http://a.test/1"),
      LauncherTab(id: "t2", title: "Kyoto food", url: "http://a.test/2"),
      LauncherTab(id: "t3", title: "Kyoto maps", url: "http://a.test/3"),
    ], activeTabId: "t1")

  private let instruction = "Find a quiet hotel in Kyoto under $200 a night"

  private func model(_ query: String = "", scope: LauncherScope = .all) -> LauncherModel {
    var model = LauncherModel()
    let generation = scope == .all ? model.setQuery(query) : model.setScope(scope)
    _ = model.apply(
      LauncherRanking.rank(query: query, snapshot: data, generation: generation, scope: scope))
    return model
  }

  @Test func theFirstRowStartsActiveAndEnterRunsIt() {
    let model = model("kyoto")
    #expect(model.activeRow?.kind == .search)
    #expect(model.rows.count == 5)
  }

  @Test func arrowsClampAtBothEnds() {
    var model = model("kyoto")
    model.moveActive(by: -1)
    #expect(model.activeRow?.kind == .search)
    for _ in 0..<10 { model.moveActive(by: 1) }
    #expect(model.activeRow?.target == "t3")
    model.moveActive(by: 1)
    #expect(model.activeRow?.target == "t3")
    model.moveActive(by: -1)
    #expect(model.activeRow?.target == "t2")
  }

  @Test func anOlderGenerationNeverReplacesNewerRows() {
    var model = LauncherModel()
    let first = model.setQuery("k")
    let second = model.setQuery("kyo")
    let early = model.apply(LauncherRanking.rank(query: "k", snapshot: data, generation: first))
    #expect(!early)
    #expect(model.rows.isEmpty)
    let current = model.apply(
      LauncherRanking.rank(query: "kyo", snapshot: data, generation: second))
    #expect(current)
    let late = model.apply(LauncherRanking.rank(query: "k", snapshot: data, generation: first))
    #expect(!late)
    #expect(model.rows.first?.kind == .search)
    #expect(model.isCurrent)
  }

  @Test func typingQuicklyEndsWhereTheFinalQueryAloneWould() {
    var typed = LauncherModel()
    let generations = ["k", "ky", "kyo"].map { typed.setQuery($0) }
    for (query, generation) in zip(
      ["kyo", "k", "ky"], [generations[2], generations[0], generations[1]])
    {
      _ = typed.apply(LauncherRanking.rank(query: query, snapshot: data, generation: generation))
    }
    let alone = model("kyo")
    #expect(typed.rows.map(\.id) == alone.rows.map(\.id))
    #expect(typed.activeId == alone.activeId)
  }

  @Test func aRefreshForTheSameQueryKeepsTheActiveRow() {
    var model = model("kyoto")
    model.moveActive(by: 2)
    let chosen = model.activeId
    let generation = model.refresh()
    var more = data
    more.history = [LauncherSite(url: "https://kyoto.example.org/", title: "Kyoto guide")]
    let applied = model.apply(
      LauncherRanking.rank(query: "kyoto", snapshot: more, generation: generation))
    #expect(applied)
    #expect(model.activeId == chosen)
    #expect(model.rows.count == 6)
  }

  @Test func aNewQueryStartsOnItsFirstRowAgain() {
    var model = model("kyoto")
    model.moveActive(by: 2)
    let generation = model.setQuery("kyoto m")
    _ = model.apply(LauncherRanking.rank(query: "kyoto m", snapshot: data, generation: generation))
    #expect(model.activeRow == model.rows.first)
  }

  @Test func theActiveRowGoesWhenItsRowGoes() {
    var model = model("kyoto")
    model.moveActive(by: 3)
    var fewer = data
    fewer.tabs = [data.tabs[0]]
    let generation = model.refresh()
    _ = model.apply(LauncherRanking.rank(query: "kyoto", snapshot: fewer, generation: generation))
    #expect(model.activeRow == model.rows.first)
  }

  @Test func anUnavailableModelDisablesStartTaskAndOffersRetry() {
    var model = model(instruction)
    #expect(model.activeRow?.kind == .startTask)
    model.setTaskUnavailable(true)
    #expect(model.rows.prefix(3).map(\.kind) == [.startTask, .retry, .search])
    #expect(model.rows[0].enabled == false)
    #expect(model.rows[0].subtitle == "Muse is unavailable. Web search still works.")
    #expect(model.activeRow?.kind == .search)
    model.moveActive(by: -1)
    #expect(model.activeRow?.kind == .retry)
    model.moveActive(by: -1)
    #expect(model.activeRow?.kind == .retry)
    model.setTaskUnavailable(false)
    #expect(model.rows.prefix(2).map(\.kind) == [.startTask, .search])
    #expect(!model.rows.contains { $0.kind == .retry })
    #expect(model.activeRow?.kind == .startTask)
  }

  @Test func recoveringKeepsAChosenSearchRow() {
    var model = model(instruction)
    model.setTaskUnavailable(true)
    #expect(model.activeRow?.kind == .search)
    model.setTaskUnavailable(false)
    #expect(model.activeRow?.kind == .search)
  }

  @Test func rowsRankedAfterTheErrorStayDisabled() {
    var model = LauncherModel()
    model.setTaskUnavailable(true)
    let generation = model.setQuery("kyoto hotels")
    _ = model.apply(
      LauncherRanking.rank(query: "kyoto hotels", snapshot: data, generation: generation))
    #expect(model.rows.map(\.kind) == [.search, .startTask, .retry])
    #expect(model.rows[1].enabled == false)
    #expect(model.activeRow?.kind == .search)
  }

  @Test func theSuggestionsAreDisabledWithoutRetryOnAnEmptyQuery() {
    var model = model("")
    model.setTaskUnavailable(true)
    let tasks = model.rows.filter { $0.kind == .startTask }
    #expect(tasks.count == 2)
    #expect(tasks.allSatisfy { !$0.enabled })
    #expect(!model.rows.contains { $0.kind == .retry })
    #expect(model.activeRow?.kind == .switchTab)
  }

  @Test func theQuerySurvivesAClose() {
    var model = model("partial que")
    model.close(committed: false)
    #expect(model.query == "partial que")
    model.close(committed: true)
    #expect(model.query == "")
    #expect(model.rows.isEmpty)
  }

  @Test func closingClearsTheErrorSoReopeningStartsClean() {
    var model = model("kyoto hotels")
    model.setTaskUnavailable(true)
    model.close(committed: false)
    #expect(!model.taskUnavailable)
  }

  @Test func reopeningStartsOnTheFirstRow() {
    var model = model("kyoto hotels")
    model.moveActive(by: 1)
    #expect(model.activeRow?.kind == .startTask)
    model.close(committed: false)
    let generation = model.reopen()
    _ = model.apply(
      LauncherRanking.rank(query: "kyoto hotels", snapshot: data, generation: generation))
    #expect(model.activeRow?.kind == .search)
  }

  @Test func aScopeStartsEmptyAndNeverOutlivesTheLauncher() {
    var model = model("kyoto")
    let generation = model.setScope(.history)
    #expect(model.scope == .history)
    #expect(model.query == "")
    #expect(model.rows.count == 5)
    _ = model.apply(
      LauncherRanking.rank(query: "", snapshot: data, generation: generation, scope: .history))
    #expect(model.rows.isEmpty)
    _ = model.setQuery("zzz")
    model.close(committed: false)
    #expect(model.scope == .all)
    #expect(model.query == "")
  }
}
