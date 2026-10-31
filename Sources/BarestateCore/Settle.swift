import Dispatch
import Foundation

/// When a page has finished reacting to an action (architecture §5.4): nothing pending and
/// nothing heard for the quiet period, or the cap. Pure: the caller supplies every clock reading.
public struct SettleTracker: Sendable {
  public let quiet: Double
  public let cap: Double
  public let navigationCap: Double
  private let start: Double
  private var lastActivity: Double
  private var inFlight: Set<String> = []
  private let mainFrame: String
  private var loading = false
  private var navigating = false
  private var committed = false
  private var domContentLoaded: Double?

  public init(
    start: Double, mainFrame: String, quiet: Double = 0.08, cap: Double = 2,
    navigationCap: Double = 10
  ) {
    self.start = start
    self.mainFrame = mainFrame
    lastActivity = start
    self.quiet = quiet
    self.cap = cap
    self.navigationCap = navigationCap
  }

  private static let navigationStarts: Set<String> = [
    "Page.frameRequestedNavigation", "Page.frameStartedNavigating", "Page.frameStartedLoading",
  ]

  /// Lifecycle events change `navigating`, `loading` and `committed` only for the main frame;
  /// every Network and Page event still counts as activity, a subframe's included.
  public mutating func record(
    _ method: String, requestId: String? = nil, frameId: String? = nil, at now: Double
  ) {
    let ownFrame = frameId == mainFrame
    switch method {
    case "Network.requestWillBeSent":
      if let requestId { inFlight.insert(requestId) }
    // The response ends the wait: loadingFinished never comes for a body the page does not read.
    case "Network.responseReceived", "Network.loadingFinished", "Network.loadingFailed":
      if let requestId { inFlight.remove(requestId) }
    case "Page.frameStartedLoading" where ownFrame:
      loading = true
    case "Page.frameStoppedLoading" where ownFrame:
      loading = false
    case "Page.frameNavigated" where ownFrame:
      committed = true
    case "Page.domContentEventFired" where committed:
      domContentLoaded = domContentLoaded ?? now
    default:
      break
    }
    if ownFrame, Self.navigationStarts.contains(method) { navigating = true }
    // A DOM mutation or scroll arrives as Runtime.bindingCalled; the rest is network or page state.
    if method.hasPrefix("Network.") || method.hasPrefix("Page.")
      || method == "Runtime.bindingCalled"
    {
      lastActivity = now
    }
  }

  /// The action itself counts as activity: the quiet period runs from the write, not the arming.
  public mutating func touch(at now: Double) { lastActivity = max(lastActivity, now) }

  /// The page is usable once it committed and fired DOMContentLoaded; slow images and long-lived
  /// requests behind that never hold the act for the whole navigation cap.
  private var capEnd: Double {
    let end = start + (navigating ? navigationCap : cap)
    return domContentLoaded.map { min(end, $0 + cap) } ?? end
  }
  private var pending: Bool { loading || !inFlight.isEmpty }

  public func isSettled(at now: Double) -> Bool {
    now >= capEnd || (!pending && now >= lastActivity + quiet)
  }

  public func isCapped(at now: Double) -> Bool {
    now >= capEnd && (pending || now < lastActivity + quiet)
  }

  /// A main-frame navigation that was still waiting for its response when its cap ran out. The
  /// browser holds every page command (`Page.getFrameTree`, `Runtime.*`, `DOM.*`) until such a
  /// navigation commits, so the caller abandons it rather than leave the tab unusable for the next
  /// act. A committed page that is still loading subresources is a usable page, never hanging.
  public func leavesNavigationHanging(at now: Double) -> Bool {
    loading && !committed && now >= capEnd
  }

  /// The earliest moment the page can count as settled if nothing else is heard.
  public var nextCheck: Double { pending ? capEnd : min(lastActivity + quiet, capEnd) }
}

extension SettleTracker {
  mutating func record(_ event: CDPEvent, at now: Double) {
    record(
      event.method, requestId: event.params["requestId"]?.string,
      frameId: event.params["frameId"]?.string ?? event.params["frame"]?["id"]?.string, at: now)
  }
}

public struct SettleResult: Sendable, Equatable {
  public let elapsedMs: Double
  public let capped: Bool
  public let navigationHanging: Bool
  /// Set by the caller once it has actually sent `Page.stopLoading`; a takeover leaves it false.
  public var navigationStopped = false

  public var json: JSON {
    [
      "ms": .number(elapsedMs.rounded()), "capped": .bool(capped),
      "navigationStopped": .bool(navigationStopped),
    ]
  }
}

/// Runs a `SettleTracker` against a tab's DevTools events. Arm it right before the write, feed it
/// every event, and wait; the deadline is a one-shot timer rescheduled by each event, never a
/// fixed pause.
@MainActor
public final class Settling {
  private let clock: @Sendable () -> Double
  private let quiet: Double
  private let cap: Double
  private let navigationCap: Double
  private var tracker: SettleTracker?
  /// The outcome of the latest `wait`, until the next `arm`.
  public private(set) var last: SettleResult?
  private var armedAt = 0.0
  private var waiter: CheckedContinuation<SettleResult, Never>?
  private var timer: DispatchSourceTimer?

  public init(
    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
    quiet: Double = 0.08, cap: Double = 2, navigationCap: Double = 10
  ) {
    self.clock = clock
    self.quiet = quiet
    self.cap = cap
    self.navigationCap = navigationCap
  }

  /// Starts (or restarts) the watch. Events fed before this are not counted. `mainFrame` is the
  /// root frame id of the page keys the action was admitted against.
  public func arm(mainFrame: String) {
    armedAt = clock()
    last = nil
    tracker = SettleTracker(
      start: armedAt, mainFrame: mainFrame, quiet: quiet, cap: cap, navigationCap: navigationCap)
  }

  /// The hanging verdict now, not at the wait's return: events handled in between may have
  /// committed the navigation.
  public func isHangingNow() -> Bool { tracker?.leavesNavigationHanging(at: clock()) ?? false }

  /// Clears the previous outcome of a tab whose watch has not been armed yet.
  public func disarm() { last = nil }

  public func markStopped() { last?.navigationStopped = true }

  public func feed(_ event: CDPEvent) {
    guard tracker != nil else { return }
    tracker?.record(event, at: clock())
    if waiter != nil { check() }
  }

  /// Returns when the page has settled. A watch that was never armed returns at once.
  public func wait() async -> SettleResult {
    guard tracker != nil else {
      return SettleResult(elapsedMs: 0, capped: false, navigationHanging: false)
    }
    tracker?.touch(at: clock())
    return await withCheckedContinuation { continuation in
      waiter = continuation
      check()
    }
  }

  private func check() {
    guard let tracker, let waiter else { return }
    let now = clock()
    if tracker.isSettled(at: now) {
      timer?.cancel()
      timer = nil
      self.waiter = nil
      let result = SettleResult(
        elapsedMs: (now - armedAt) * 1000, capped: tracker.isCapped(at: now),
        navigationHanging: tracker.leavesNavigationHanging(at: now))
      last = result
      waiter.resume(returning: result)
      return
    }
    let delay = max(tracker.nextCheck - now, 0.001)
    timer?.cancel()
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now() + delay)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.check() } }
    source.resume()
    timer = source
  }
}

extension Settling {
  /// What the tracker listens to besides the network and page events: DOM mutations and scrolls,
  /// reported by a binding in the isolated world. `__bsStop` takes the watch down again.
  private static let watch = """
    (() => {
      if (globalThis.__bsStop) return;
      const ping = () => globalThis.__bsSettle("1");
      const observer = new MutationObserver(ping);
      observer.observe(document,
        { subtree: true, childList: true, attributes: true, characterData: true });
      addEventListener("scroll", ping, { capture: true, passive: true });
      globalThis.__bsStop = () => {
        observer.disconnect();
        removeEventListener("scroll", ping, true);
        delete globalThis.__bsStop;
      };
    })()
    """

  /// Turns on the event domains and the page watch for the length of one action. They stay off
  /// otherwise, so a browsing tab pays nothing. Returns the isolated world to hand to `release`.
  public static func prepare(_ channel: CDPChannel) async -> Int? {
    let enables = ["Page.enable", "Network.enable", "Runtime.enable"].map {
      channel.submit($0, [:])
    }
    for enable in enables { _ = try? await enable() }
    guard let context = try? await Extractor.isolatedContext(channel) else { return nil }
    _ = try? await channel.send(
      "Runtime.addBinding",
      ["name": "__bsSettle", "executionContextId": .number(Double(context))])
    _ = try? await channel.send(
      "Runtime.evaluate", ["contextId": .number(Double(context)), "expression": .string(watch)])
    return context
  }

  /// Not awaited: with a navigation still pending the browser answers `Page.disable` only when it
  /// ends, which would hold the action past its cap. Later commands queue behind these in order.
  public static func release(_ channel: CDPChannel, context: Int?) {
    if let context {
      _ = channel.submit(
        "Runtime.evaluate",
        ["contextId": .number(Double(context)), "expression": "globalThis.__bsStop?.()"])
      _ = channel.submit("Runtime.removeBinding", ["name": "__bsSettle"])
    }
    for method in ["Runtime.disable", "Network.disable", "Page.disable"] {
      _ = channel.submit(method, [:])
    }
  }
}
