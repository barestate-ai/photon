import Foundation

/// The two values that say whether a page still looks the way an observation recorded it:
/// `documentKey` changes with every new document, `viewportKey` with scroll, size and scale.
public struct PageKeys: Sendable, Equatable {
  public let documentKey: String
  public let viewportKey: String

  public init(documentKey: String, viewportKey: String) {
    self.documentKey = documentKey
    self.viewportKey = viewportKey
  }

  /// Pure reduction of `Page.getFrameTree`, `Page.getLayoutMetrics` and `window.devicePixelRatio`.
  static func parse(frameTree: JSON, metrics: JSON, dpr: Double) throws -> PageKeys {
    let documentKey = try documentKey(frameTree: frameTree)
    guard let visual = metrics["cssVisualViewport"], let layout = metrics["cssLayoutViewport"],
      let scrollX = visual["pageX"]?.number, let scrollY = visual["pageY"]?.number,
      let width = layout["clientWidth"]?.number, let height = layout["clientHeight"]?.number
    else { throw ObservationError.malformed("Page.getLayoutMetrics: no css viewport") }
    return PageKeys(
      documentKey: documentKey,
      viewportKey:
        "\(format(scrollX)),\(format(scrollY)),\(format(width))x\(format(height))@\(format(dpr))")
  }

  /// The main frame and the loader of its current document: a navigation, a reload included,
  /// gets a new loader.
  public static func documentKey(frameTree: JSON) throws -> String {
    guard let frame = frameTree["frameTree"]?["frame"],
      let frameId = frame["id"]?.string, let loaderId = frame["loaderId"]?.string
    else { throw ObservationError.malformed("Page.getFrameTree: no main frame") }
    return "\(frameId):\(loaderId)"
  }

  /// The main frame's id, the part of `documentKey` that survives navigations.
  public static func mainFrameId(documentKey: String) -> String {
    String(documentKey.prefix { $0 != ":" })
  }

  /// The page's keys right now: three reads sent together.
  public static func read(_ transport: any CDPTransport) async throws -> PageKeys {
    async let frameTree = transport.send("Page.getFrameTree", [:])
    async let metrics = transport.send("Page.getLayoutMetrics", [:])
    async let dpr = transport.send(
      "Runtime.evaluate", ["expression": "window.devicePixelRatio", "returnByValue": true])
    return try parse(
      frameTree: try await frameTree, metrics: try await metrics,
      dpr: try await dpr["result"]?["value"]?.number ?? 1)
  }

  static func format(_ number: Double) -> String {
    Int(exactly: number).map(String.init) ?? String(format: "%.2f", number)
  }
}
