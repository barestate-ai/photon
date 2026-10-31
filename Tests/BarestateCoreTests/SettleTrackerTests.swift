import BarestateCore
import Testing

struct SettleTrackerTests {
  private let main = "main"

  private func tracker(_ start: Double = 0) -> SettleTracker {
    SettleTracker(start: start, mainFrame: main)
  }

  @Test func aPageThatNeverSpeaksIsSettledAfterTheQuietPeriod() {
    let settle = tracker()
    #expect(!settle.isSettled(at: 0.079))
    #expect(settle.isSettled(at: 0.08))
    #expect(settle.nextCheck == 0.08)
  }

  @Test func everyEventRestartsTheQuietPeriod() {
    var settle = tracker()
    settle.record("Page.frameNavigated", frameId: main, at: 0.05)
    #expect(!settle.isSettled(at: 0.12))
    #expect(settle.isSettled(at: 0.131))
  }

  @Test func theActionItselfStartsTheQuietPeriod() {
    var settle = tracker()
    settle.touch(at: 0.05)
    #expect(!settle.isSettled(at: 0.12))
    #expect(settle.isSettled(at: 0.131))
  }

  @Test func aRequestInFlightHoldsTheSettleUntilItsResponseThenWaitsTheQuietPeriod() {
    var settle = tracker()
    settle.record("Network.requestWillBeSent", requestId: "1", at: 0.01)
    #expect(!settle.isSettled(at: 0.5))
    settle.record("Network.loadingFinished", requestId: "1", at: 0.61)
    #expect(!settle.isSettled(at: 0.68))
    #expect(settle.isSettled(at: 0.691))
  }

  @Test func theResponseEndsTheWaitWithoutTheBodyBeingRead() {
    var settle = tracker()
    settle.record("Network.requestWillBeSent", requestId: "1", at: 0.01)
    settle.record("Network.responseReceived", requestId: "1", at: 0.61)
    #expect(!settle.isSettled(at: 0.68))
    #expect(settle.isSettled(at: 0.691))
  }

  @Test func aFailedRequestEndsItsWaitToo() {
    var settle = tracker()
    settle.record("Network.requestWillBeSent", requestId: "1", at: 0)
    settle.record("Network.loadingFailed", requestId: "1", at: 0.2)
    #expect(settle.isSettled(at: 0.281))
  }

  @Test func aRedirectReusesTheRequestIdAndStaysOneRequest() {
    var settle = tracker()
    settle.record("Network.requestWillBeSent", requestId: "1", at: 0)
    settle.record("Network.requestWillBeSent", requestId: "1", at: 0.1)
    settle.record("Network.loadingFinished", requestId: "1", at: 0.2)
    #expect(settle.isSettled(at: 0.281))
  }

  @Test func aFinishForARequestStartedBeforeTheWatchChangesNothingButTheQuietPeriod() {
    var settle = tracker()
    settle.record("Network.loadingFinished", requestId: "old", at: 0.01)
    #expect(settle.isSettled(at: 0.091))
  }

  @Test func aPageThatKeepsChangingIsCutOffAtTwoSeconds() {
    var settle = tracker()
    var now = 0.0
    while now < 1.99 {
      now += 0.05
      settle.record("Runtime.bindingCalled", at: now)
    }
    #expect(!settle.isSettled(at: 1.99))
    #expect(settle.isSettled(at: 2.0))
    #expect(settle.isCapped(at: 2.0))
  }

  @Test func aNavigationRaisesTheCapToTenSecondsAndWaitsForTheLoad() {
    var settle = tracker()
    settle.record("Page.frameRequestedNavigation", frameId: main, at: 0.01)
    settle.record("Network.requestWillBeSent", requestId: "doc", at: 0.02)
    #expect(!settle.isSettled(at: 2.5))
    settle.record("Network.loadingFinished", requestId: "doc", at: 3.05)
    settle.record("Page.frameStoppedLoading", frameId: main, at: 3.06)
    #expect(settle.isSettled(at: 3.141))
    #expect(!settle.isCapped(at: 3.141))
  }

  @Test func aNavigationThatNeverCompletesStopsAtTenSeconds() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    #expect(!settle.isSettled(at: 9.99))
    #expect(settle.isSettled(at: 10))
    #expect(settle.isCapped(at: 10))
  }

  @Test func aMainFrameThatNeverCommittedIsHangingAtItsCap() {
    var settle = tracker()
    settle.record("Page.frameRequestedNavigation", frameId: main, at: 0.01)
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.02)
    #expect(!settle.leavesNavigationHanging(at: 9.99))
    #expect(settle.leavesNavigationHanging(at: 10))
  }

  @Test func aCommittedPageStillLoadingAtTheCapIsNotHanging() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameNavigated", frameId: main, at: 0.1)
    settle.record("Network.requestWillBeSent", requestId: "image", at: 0.2)
    #expect(settle.isSettled(at: 10))
    #expect(!settle.leavesNavigationHanging(at: 10))
  }

  @Test func aNavigationThatStopsWithoutCommittingIsNotHanging() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameStoppedLoading", frameId: main, at: 0.3)
    #expect(!settle.leavesNavigationHanging(at: 10))
    #expect(settle.isSettled(at: 0.381))
  }

  @Test func aSubframeNeverRaisesTheCapNorHangsThePage() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: "ad", at: 0.01)
    settle.record("Network.requestWillBeSent", requestId: "ad-doc", at: 0.02)
    #expect(!settle.isSettled(at: 1.99))
    #expect(settle.isSettled(at: 2))
    #expect(settle.isCapped(at: 2))
    #expect(!settle.leavesNavigationHanging(at: 2))
    #expect(settle.nextCheck == 2)
  }

  @Test func aSubframeStoppingDoesNotEndTheMainFramesLoad() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameStartedLoading", frameId: "ad", at: 0.02)
    settle.record("Page.frameStoppedLoading", frameId: "ad", at: 0.03)
    #expect(!settle.isSettled(at: 5))
    #expect(settle.leavesNavigationHanging(at: 10))
  }

  @Test func aSubframeCommitDoesNotCountAsTheMainFrameCommitting() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameNavigated", frameId: "ad", at: 0.1)
    #expect(settle.leavesNavigationHanging(at: 10))
  }

  @Test func afterTheCommitAndDomContentLoadedTheWaitEndsTwoSecondsLater() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameNavigated", frameId: main, at: 0.2)
    #expect(settle.nextCheck == 10)
    settle.record("Page.domContentEventFired", at: 0.3)
    settle.record("Network.requestWillBeSent", requestId: "image", at: 0.35)
    #expect(!settle.isSettled(at: 2.29))
    #expect(settle.isSettled(at: 2.3))
    #expect(settle.isCapped(at: 2.3))
    #expect(settle.nextCheck == 2.3)
  }

  @Test func domContentLoadedPastTheShortenedCapChangesNothing() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.frameNavigated", frameId: main, at: 0.2)
    settle.record("Network.requestWillBeSent", requestId: "doc-image", at: 0.3)
    settle.record("Page.domContentEventFired", at: 9.5)
    #expect(settle.isSettled(at: 10))
    #expect(!settle.isSettled(at: 9.9))
  }

  @Test func domContentLoadedBeforeTheCommitIsIgnored() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0.01)
    settle.record("Page.domContentEventFired", at: 0.2)
    #expect(settle.nextCheck == 10)
  }

  @Test func theLoadingFlagHoldsUntilTheFrameStopsLoading() {
    var settle = tracker()
    settle.record("Page.frameStartedLoading", frameId: main, at: 0)
    settle.record("Page.frameNavigated", frameId: main, at: 0.05)
    #expect(!settle.isSettled(at: 1))
    settle.record("Page.frameStoppedLoading", frameId: main, at: 1.1)
    #expect(settle.isSettled(at: 1.181))
  }

  @Test func nextCheckIsTheCapWhileSomethingIsPending() {
    var settle = tracker(5)
    settle.record("Network.requestWillBeSent", requestId: "1", at: 5.1)
    #expect(settle.nextCheck == 7)
    settle.record("Page.frameRequestedNavigation", frameId: main, at: 5.2)
    #expect(settle.nextCheck == 15)
  }

  @Test func theMainFrameIdIsTheDocumentKeysFrameHalf() {
    #expect(PageKeys.mainFrameId(documentKey: "A1B2:C3D4") == "A1B2")
  }

  @Test func eventsThatAreNotPageActivityAreIgnored() {
    var settle = tracker()
    settle.record("Runtime.executionContextCreated", at: 0.07)
    #expect(settle.isSettled(at: 0.08))
  }
}
