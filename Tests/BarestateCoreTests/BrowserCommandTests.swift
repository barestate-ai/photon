import BarestateCore
import Testing

struct BrowserCommandTests {
  private func availability(
    _ command: BrowserCommand, _ change: (inout BrowserCommand.Context) -> Void = { _ in }
  )
    -> BrowserCommand.Availability
  {
    var context = BrowserCommand.Context()
    change(&context)
    return command.availability(in: context)
  }

  @Test func historyOpenPagesAndSettingsAlwaysRun() {
    #expect(availability(.openPages) == .enabled)
    #expect(BrowserCommand.openPages.title(in: .init()) == "Open pages")
    #expect(availability(.history) == .enabled)
    #expect(availability(.settings) == .enabled)
  }

  @Test func pageCommandsNeedAPage() {
    for command in [BrowserCommand.reload, .find] {
      #expect(availability(command) == .disabled("No page is open"))
      #expect(availability(command) { $0.hasPage = true } == .enabled)
    }
  }

  @Test func aBlankTabCanBeClosedButNotReloadedOrSearched() {
    #expect(availability(.closePage) == .disabled("No page is open"))
    #expect(availability(.closePage) { $0.hasTab = true } == .enabled)
    #expect(availability(.reload) { $0.hasTab = true } == .disabled("No page is open"))
    #expect(
      availability(.find) {
        $0.hasTab = true
        $0.presentation = .focused
      } == .disabled("No page is open"))
  }

  @Test func findNeedsTheFocusedPage() {
    #expect(
      availability(.find) {
        $0.hasPage = true
        $0.presentation = .overview
      } == .disabled("Open a page to search in it"))
    #expect(
      availability(.find) {
        $0.hasPage = true
        $0.presentation = .focused
      } == .enabled)
    #expect(
      availability(.find) { $0.presentation = .focused } == .disabled("No page is open"))
  }

  @Test func backAndForwardFollowTheHistory() {
    #expect(availability(.back) != .enabled)
    #expect(availability(.back) { $0.canGoBack = true } == .enabled)
    #expect(availability(.forward) != .enabled)
    #expect(availability(.forward) { $0.canGoForward = true } == .enabled)
  }

  @Test func reopenNeedsAClosedPage() {
    #expect(availability(.reopenClosed) != .enabled)
    #expect(availability(.reopenClosed) { $0.hasClosedPage = true } == .enabled)
  }

  @Test func zoomAppliesToTheOverview() {
    #expect(
      availability(.zoomIn) { $0.presentation = .focused }
        == .disabled("Zoom applies to the overview"))
    #expect(
      availability(.zoomToFit) { $0.presentation = .focused }
        == .disabled("Zoom applies to the overview"))
    #expect(availability(.zoomIn) { $0.presentation = .overview } == .enabled)
    #expect(availability(.zoomOut) { $0.presentation = .focused } == .enabled)
  }

  @Test func switchingPresentationNamesWhatIsAlreadyShown() {
    #expect(availability(.showOverview) { $0.presentation = .overview } != .enabled)
    #expect(availability(.showOverview) { $0.presentation = .focused } == .enabled)
    #expect(
      availability(.focusPage) { $0.presentation = .overview } == .disabled("No page to show"))
    #expect(
      availability(.focusPage) {
        $0.presentation = .focused
        $0.hasNode = true
      } == .disabled("Already showing the page"))
    #expect(
      availability(.focusPage) {
        $0.presentation = .overview
        $0.hasNode = true
      } == .enabled)
  }

  @Test func stopNeedsAnActiveRun() {
    #expect(availability(.stopRun) == .disabled("No task is running"))
    var book = RunBook()
    var run = book.start(prompt: "Compare stays", origin: .mac, ownerTabId: nil)!
    run.state = .running
    var context = BrowserCommand.Context()
    context.activeRun = run
    #expect(BrowserCommand.stopRun.availability(in: context) == .enabled)
    #expect(BrowserCommand.stopRun.title(in: context) == "Stop Compare stays")
  }

  @Test func disconnectPhoneNeedsAConnectedPhone() {
    #expect(availability(.disconnectPhone) == .disabled("No phone is connected"))
    #expect(availability(.disconnectPhone) { $0.phoneConnected = true } == .enabled)
    #expect(BrowserCommand.disconnectPhone.title(in: .init()) == "Disconnect phone")
  }

  @Test func everyDisabledCommandGivesAReason() {
    for command in BrowserCommand.allCases {
      if case .disabled(let reason) = availability(command) {
        #expect(!reason.isEmpty, "\(command)")
      }
    }
  }
}
