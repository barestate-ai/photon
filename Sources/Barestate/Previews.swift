import BarestateCore
import Foundation

/// Captures a visible page into the cache on the page graph's canvas. Each capture is stamped
/// with the tab's document and kept only if that document is still current when it arrives.
/// When to capture is the presentation's business; this is the capture itself.
@MainActor
final class Previews {
  enum Outcome: String {
    case stored, rejectedStale, tooLarge, notVisible, noPage, failed
  }

  static let logLimit = 128
  /// An overview card's pixels at 2x.
  static let cardWidth = 440
  static let cardHeight = 368

  private unowned let app: AppController
  private(set) var log: [JSON] = []
  /// Test hook: the next capture stops after the screenshot is taken, until `release`.
  var holdNext = false
  /// Test hook: off, a navigation settling in the focused page does not capture it.
  var autoCapture = true
  private var gate: CheckedContinuation<Void, Never>?
  private var gateWaiter: CheckedContinuation<Void, Never>?

  init(app: AppController) {
    self.app = app
  }

  var isHeld: Bool { gate != nil }

  func release() {
    gate?.resume()
    gate = nil
  }

  /// Returns once a held capture has reached the gate, or has ended without reaching it.
  func waitUntilHeldOrDone() async {
    guard gate == nil else { return }
    await withCheckedContinuation { gateWaiter = $0 }
  }

  // MARK: When the presentation captures

  private func capturable(_ tab: Tab) -> Bool {
    !app.quitting && !tab.view.isHiddenOrHasHiddenAncestor
      && app.canvas.graph.nodeId(forTab: tab.id) != nil
  }

  /// The page being left for the overview, before the overview shows. A capture slower than
  /// `Motion.previewCaptureTimeout` keeps running and is checked against the document like any
  /// other when it lands; the overview meanwhile shows what is stored.
  func captureForOverview(_ tab: Tab) async {
    guard capturable(tab) else { return }
    let race = CaptureRace()
    let timer = Task {
      do { try await Task.sleep(for: Motion.previewCaptureTimeout) } catch { return }
      race.finish(inTime: false)
    }
    Task {
      _ = await capture(tab, cardWidth: Self.cardWidth, cardHeight: Self.cardHeight)
      timer.cancel()
      race.finish(inTime: true)
    }
    if await race.inTime() == false { MotionLedger.shared.noteCaptureTimeout() }
  }

  /// A navigation finished in the page being looked at.
  func captureSettled(_ tab: Tab) {
    guard autoCapture, capturable(tab) else { return }
    Task { _ = await capture(tab, cardWidth: Self.cardWidth, cardHeight: Self.cardHeight) }
  }

  // MARK: Documents

  /// A navigation committed in `browserId`. A new document marks the node's preview stale.
  func documentCommitted(browserId: Int32) {
    guard let tab = app.tab(browserId: browserId) else { return }
    tab.documentGeneration += 1
    // Marked before the key is read: a slow or failed reply must not leave the old image fresh.
    if tab.documentKey != nil, let node = app.canvas.graph.nodeId(forTab: tab.id) {
      app.canvas.previews.markStale(node)
      app.canvas.changed?()
    }
    Task { _ = await readDocumentKey(tab) }
  }

  /// The tab's current document, as the main frame's loader. Tabs with no node have no
  /// previews, so their key is not tracked: the blank page a tab starts on is not a document
  /// whose replacement makes anything stale. `reply` is a `Page.getFrameTree` already sent, at
  /// `generation`: a reply older than a commit describes a document that is gone, so it is not
  /// adopted (the commit reads the new key itself).
  func readDocumentKey(
    _ tab: Tab, reply: (() async throws -> JSON)? = nil, generation: Int? = nil
  ) async -> String? {
    let generation = generation ?? tab.documentGeneration
    do {
      let tree = reply ?? tab.channel.submit("Page.getFrameTree", [:])
      let key = try PageKeys.documentKey(frameTree: try await tree())
      if tab.documentGeneration == generation { adopt(key, for: tab) }
      return key
    } catch {
      Log.error(.canvas, "preview document key failed tab=\(tab.id) \(Log.describe(error))")
      return nil
    }
  }

  private func adopt(_ key: String, for tab: Tab) {
    guard key != tab.documentKey else { return }
    guard let node = app.canvas.graph.nodeId(forTab: tab.id) else {
      tab.documentKey = nil
      return
    }
    let tracked = tab.documentKey != nil
    tab.documentKey = key
    // A revived page starts untracked but its node still holds the old document's image.
    if tracked || app.canvas.previews.state(of: node) != .none {
      app.canvas.previews.markStale(node)
      app.canvas.changed?()
    }
  }

  // MARK: Capture

  func capture(_ tab: Tab, cardWidth: Int, cardHeight: Int) async -> Outcome {
    defer {
      gateWaiter?.resume()
      gateWaiter = nil
    }
    var record: [String: JSON] = [
      "tabId": .string(tab.id), "startedMs": .number(Date().timeIntervalSince1970 * 1000),
    ]
    let outcome = await run(tab, cardWidth, cardHeight, &record)
    record["outcome"] = .string(outcome.rawValue)
    record["finishedMs"] = .number(Date().timeIntervalSince1970 * 1000)
    log.append(.object(record))
    if log.count > Self.logLimit { log.removeFirst() }
    Log.info(.canvas, "preview capture tab=\(tab.id) outcome=\(outcome.rawValue)")
    return outcome
  }

  private func run(
    _ tab: Tab, _ cardWidth: Int, _ cardHeight: Int, _ record: inout [String: JSON]
  ) async -> Outcome {
    guard !tab.view.isHiddenOrHasHiddenAncestor else { return .notVisible }
    guard let node = app.canvas.graph.nodeId(forTab: tab.id) else { return .noPage }
    record["node"] = .string(node)
    let generation = tab.documentGeneration
    do {
      // Sent together: the key is read before the screenshot runs, so a navigation in between
      // shows as a different key when the capture is decided.
      let tree = tab.channel.submit("Page.getFrameTree", [:])
      let shot = tab.channel.submit("Page.captureScreenshot", PreviewCapture.screenshot)
      guard let stamp = await readDocumentKey(tab, reply: tree, generation: generation) else {
        throw PreviewCapture.Failure(message: "no document key")
      }
      record["documentKey"] = .string(stamp)
      guard let encoded = try await shot()["data"]?.string else {
        throw PreviewCapture.Failure(message: "no data")
      }
      // The document is read again while the image decodes.
      let again = tab.channel.submit("Page.getFrameTree", [:])
      if holdNext {
        holdNext = false
        await withCheckedContinuation {
          gate = $0
          gateWaiter?.resume()
          gateWaiter = nil
        }
      }
      let decoded = await Task.detached(priority: .utility) {
        let jpeg = Data(base64Encoded: encoded) ?? Data()
        return Decoded(
          preview: PreviewDecoder.decode(
            jpeg, documentKey: stamp, cardWidth: cardWidth, cardHeight: cardHeight),
          jpegBytes: jpeg.count, magic: jpeg.prefix(3).map { String(format: "%02x", $0) }.joined(),
          onMain: pthread_main_np() != 0)
      }.value
      record["jpegBytes"] = .number(Double(decoded.jpegBytes))
      record["magic"] = .string(decoded.magic)
      record["decodedOnMain"] = .bool(decoded.onMain)
      guard let preview = decoded.preview else {
        throw PreviewCapture.Failure(message: "undecodable")
      }
      record["width"] = .number(Double(preview.image.width))
      record["height"] = .number(Double(preview.image.height))
      // Decide with no suspension after the key is read: a navigation after the screenshot
      // changes the key, and a page closed meanwhile has no node to receive it.
      let current = await readDocumentKey(tab, reply: again, generation: generation)
      let alive =
        app.tab(id: tab.id) === tab && app.canvas.graph.nodeId(forTab: tab.id) == node
        && tab.documentGeneration == generation
      let outcome = app.canvas.previews.offer(
        preview, node: node, currentKey: alive ? current : nil)
      app.canvas.changed?()
      switch outcome {
      case .stored: return .stored
      case .rejectedStale: return .rejectedStale
      case .tooLarge: return .tooLarge
      }
    } catch {
      Log.error(.canvas, "preview capture failed tab=\(tab.id) \(Log.describe(error))")
      return .failed
    }
  }

  /// Whichever of a capture and its deadline finishes first decides; the other is ignored.
  @MainActor
  private final class CaptureRace {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func finish(inTime: Bool) {
      guard result == nil else { return }
      result = inTime
      waiter?.resume(returning: inTime)
      waiter = nil
    }

    func inTime() async -> Bool {
      if let result { return result }
      return await withCheckedContinuation { waiter = $0 }
    }
  }

  private struct Decoded: Sendable {
    let preview: Preview?
    let jpegBytes: Int
    let magic: String
    let onMain: Bool
  }

  // MARK: Test state

  func state() -> JSON {
    let cache = app.canvas.previews
    return [
      "count": .number(Double(cache.count)), "bytes": .number(Double(cache.bytes)),
      "limits": [
        "count": .number(Double(cache.limits.count)),
        "bytes": .number(Double(cache.limits.bytes)),
      ],
      "captures": .number(Double(cache.captures)),
      "rejectedStale": .number(Double(cache.rejectedStale)),
      "evictions": .number(Double(cache.evictions)),
      "autoCapture": .bool(autoCapture), "holdNext": .bool(holdNext), "held": .bool(isHeld),
      "log": .array(log),
    ]
  }
}
