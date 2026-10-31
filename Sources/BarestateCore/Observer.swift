public enum Observer {
  public static let attempts = 3

  /// The five reads go out together, so the page can navigate or scroll between them and pair
  /// old elements with new keys. The keys are read before and after; a collection is kept only
  /// when they match, so an Observation's keys always describe its elements.
  public static func observe(
    transport: any CDPTransport, id: String, tabId: String, epoch: UInt64
  ) async throws -> Observation {
    for _ in 0..<attempts {
      let before = try await PageKeys.read(transport)
      let raw = try await collect(transport)
      let observation = try Observation.build(id: id, tabId: tabId, epoch: epoch, raw: raw)
      let after = try await PageKeys.read(transport)
      let keys = PageKeys(
        documentKey: observation.documentKey, viewportKey: observation.viewportKey)
      if before == after && after == keys { return observation }
    }
    throw ObservationError.unstable
  }

  private static func collect(_ transport: any CDPTransport) async throws -> RawObservation {
    async let snapshot = transport.send(
      "DOMSnapshot.captureSnapshot", ["computedStyles": ["display", "visibility", "opacity"]])
    async let ax = transport.send("Accessibility.getFullAXTree", [:])
    async let metrics = transport.send("Page.getLayoutMetrics", [:])
    async let frameTree = transport.send("Page.getFrameTree", [:])
    async let dpr = transport.send(
      "Runtime.evaluate", ["expression": "window.devicePixelRatio", "returnByValue": true])
    return RawObservation(
      snapshot: try await snapshot, ax: try await ax, metrics: try await metrics,
      frameTree: try await frameTree, dpr: try await dpr["result"]?["value"]?.number ?? 1)
  }
}
