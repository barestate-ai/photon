import Testing

@testable import BarestateCore

@Suite struct CardActionTests {
  @Test func aCardMenuOffersOpenMaximizeAndClosePageInThatOrder() {
    #expect(CardAction.allCases.map(\.title) == ["Open", "Maximize", "Close Page"])
  }

  @Test func onlyALivePageCanBeClosed() {
    #expect(CardAction.allCases.filter { !$0.isAvailable(live: false) } == [.closePage])
    #expect(CardAction.allCases.allSatisfy { $0.isAvailable(live: true) })
  }
}
