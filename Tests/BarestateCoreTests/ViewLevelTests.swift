import Testing

@testable import BarestateCore

@Suite struct ViewLevelTests {
  @Test func aFocusedPageFillsTheWindowOnlyWhenAskedAndTheOverviewNever() {
    #expect(ViewLevel(.overview, fillsWindow: false) == .overview)
    #expect(ViewLevel(.overview, fillsWindow: true) == .overview)
    #expect(ViewLevel(.focused, fillsWindow: false) == .focused)
    #expect(ViewLevel(.focused, fillsWindow: true) == .fullWindow)
    #expect(ViewLevel.fullWindow.rawValue == "full-window")
  }

  @Test func steppingOutWalksFullWindowToFocusToOverviewOneLevelAtATime() {
    #expect(ViewLevel.fullWindow.steppedOut == .focused)
    #expect(ViewLevel.focused.steppedOut == .overview)
    #expect(ViewLevel.overview.steppedOut == .overview)
  }

  @Test func theFullWindowKeyNeedsAPageOrASelectedCardToAct() {
    #expect(ViewLevel.focused.canToggleFullWindow(hasSelection: false))
    #expect(ViewLevel.fullWindow.canToggleFullWindow(hasSelection: false))
    #expect(ViewLevel.overview.canToggleFullWindow(hasSelection: true))
    #expect(!ViewLevel.overview.canToggleFullWindow(hasSelection: false))
  }

  @Test func leavingFullWindowReturnsToWhereTheMaximizeStartedFrom() {
    #expect(ViewLevel.fullWindow.exited(maximizedFromOverview: true) == .overview)
    #expect(ViewLevel.fullWindow.exited(maximizedFromOverview: false) == .focused)
    #expect(ViewLevel.focused.exited(maximizedFromOverview: true) == .focused)
    #expect(ViewLevel.overview.exited(maximizedFromOverview: false) == .overview)
  }
}
