import Foundation

public struct CanvasPoint: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// Camera over the canvas. Zoom is clamped on every write, so no caller can hold 0 or NaN.
public struct Viewport: Equatable, Sendable {
  public static let zoomRange = 0.2...1.5

  public var cx: Double
  public var cy: Double
  public private(set) var zoom: Double

  public init(cx: Double = 0, cy: Double = 0, zoom: Double = 1) {
    self.cx = cx.isFinite ? cx : 0
    self.cy = cy.isFinite ? cy : 0
    self.zoom =
      zoom.isFinite ? min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : 1
  }
}

public enum EdgeKind: String, Sendable {
  case openedFrom, navigatedFrom, museUsed
}

/// One page, drawn once. `tabId` is the live/archived switch, so a closed page cannot claim a tab.
public struct PageNode: Equatable, Sendable {
  public let id: String
  public var tabId: String?
  public var url: String
  public var title: String
  /// Centre of the node's slot in canvas coordinates.
  public var x: Double
  public var y: Double
  public var updatedAt: Double

  public var isArchived: Bool { tabId == nil }

  public init(
    id: String, tabId: String?, url: String, title: String, x: Double, y: Double,
    updatedAt: Double = 0
  ) {
    self.id = id
    self.tabId = tabId
    self.url = url
    self.title = title
    self.x = x
    self.y = y
    self.updatedAt = updatedAt
  }
}

public struct PageEdge: Equatable, Sendable {
  public let from: String
  public let to: String
  public let kind: EdgeKind
  public let runId: String?

  public init(from: String, to: String, kind: EdgeKind, runId: String? = nil) {
    self.from = from
    self.to = to
    self.kind = kind
    self.runId = runId
  }
}

/// How a tab came to exist; the only way an edge is ever created besides `museUsed`.
public enum NewTabOrigin: Equatable, Sendable {
  case none
  case from(node: String, kind: EdgeKind)
  /// The tab revives this archived node instead of adding a new one.
  case reopen(node: String)
}

/// The pages a person has open or recently closed, and the real events that connect them.
/// Pure: the app feeds it tab events and persists the result.
public struct PageGraph: Equatable, Sendable {
  public static let archiveLimit = 40
  public static let defaultTitle = "Your pages"
  /// A node's card plus caption is 220 x 230 pt. Neighbouring slots leave 96 pt across and 64 pt
  /// down between cards, enough for a trail to read as a curve (frame 777:24 leaves 72-140).
  public static let nodeWidth = 220.0
  public static let nodeHeight = 230.0
  public static let slotWidth = nodeWidth + 96
  public static let slotHeight = nodeHeight + 64

  public private(set) var nodes: [PageNode] = []
  public private(set) var edges: [PageEdge] = []
  public private(set) var title = PageGraph.defaultTitle
  public var viewport = Viewport()
  /// The viewport came from a saved canvas with pages, so it is the person's, whatever its values.
  public private(set) var hasRestoredCamera = false
  private var nextId = 1

  public init() {}

  /// A new session never claims a live page: every saved node comes back archived, in place.
  /// A canvas saved with no pages never had a camera worth keeping, and a nil `viewport` is one
  /// that was never saved.
  public init(restoring nodes: [PageNode], edges: [PageEdge], title: String, viewport: Viewport?) {
    self.nodes = nodes.map { node in
      var node = node
      node.tabId = nil
      return node
    }
    self.edges = edges
    self.viewport = viewport ?? Viewport()
    hasRestoredCamera = viewport != nil && !nodes.isEmpty
    setTitle(title)
    nextId = (nodes.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
    prune()
  }

  public func nodeId(forTab tab: String) -> String? {
    nodes.first { $0.tabId == tab }?.id
  }

  /// The newest closed page at `url`, for ⌘⇧T to revive in place.
  public func lastArchivedId(url: String) -> String? {
    nodes.filter { $0.isArchived && $0.url == url }.max(by: Self.closedBefore)?.id
  }

  public mutating func setTitle(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    title = trimmed.isEmpty ? Self.defaultTitle : trimmed
  }

  /// Follows a tab. Pages with no committed address are not nodes: a tab that goes blank leaves
  /// its page archived, and Chromium's error page changes nothing. Returns whether the graph
  /// changed.
  @discardableResult
  public mutating func observe(
    tab: String, url: String, title: String, origin: NewTabOrigin, now: Double
  ) -> Bool {
    guard !url.hasPrefix("chrome-error:") else { return false }
    if AddressInput.isBlank(url) { return close(tab: tab, now: now) }
    if let index = nodes.firstIndex(where: { $0.tabId == tab }) {
      guard nodes[index].url != url || nodes[index].title != title else { return false }
      nodes[index].url = url
      nodes[index].title = title
      nodes[index].updatedAt = now
      return true
    }
    if case .reopen(let id) = origin, let index = nodes.firstIndex(where: { $0.id == id }),
      nodes[index].isArchived
    {
      nodes[index].tabId = tab
      nodes[index].url = url
      nodes[index].title = title
      nodes[index].updatedAt = now
      return true
    }
    var source: CanvasPoint?
    if case .from(let id, _) = origin, let node = nodes.first(where: { $0.id == id }) {
      source = CanvasPoint(x: node.x, y: node.y)
    }
    let spot = Self.place(near: source, occupied: nodes.map { CanvasPoint(x: $0.x, y: $0.y) })
    let node = PageNode(
      id: "n\(nextId)", tabId: tab, url: url, title: title, x: spot.x, y: spot.y, updatedAt: now)
    nextId += 1
    nodes.append(node)
    if source != nil, case .from(let id, let kind) = origin {
      addEdge(PageEdge(from: id, to: node.id, kind: kind))
    }
    return true
  }

  /// The page stays as an archived node; the oldest archived ones beyond the limit go.
  @discardableResult
  public mutating func close(tab: String, now: Double) -> Bool {
    guard let index = nodes.firstIndex(where: { $0.tabId == tab }) else { return false }
    nodes[index].tabId = nil
    nodes[index].updatedAt = now
    prune()
    return true
  }

  @discardableResult
  public mutating func move(node id: String, to point: CanvasPoint) -> Bool {
    guard let index = nodes.firstIndex(where: { $0.id == id }),
      nodes[index].x != point.x || nodes[index].y != point.y
    else { return false }
    nodes[index].x = point.x
    nodes[index].y = point.y
    return true
  }

  /// A run touched `usedTab` while it belongs to `ownerTab`: one trail edge per run and pair.
  @discardableResult
  public mutating func museUsed(run: String, ownerTab: String, usedTab: String) -> Bool {
    guard ownerTab != usedTab, let from = nodeId(forTab: ownerTab),
      let to = nodeId(forTab: usedTab)
    else { return false }
    return addEdge(PageEdge(from: from, to: to, kind: .museUsed, runId: run))
  }

  /// The run's trail edge into the page it used most recently. `pages` are the run's step tabs,
  /// newest first; one edge per run and pair means edge order says nothing about recency.
  public func newestTrail(run: String, pages: some Sequence<String>) -> PageEdge? {
    for page in pages {
      guard let to = nodeId(forTab: page) else { continue }
      if let edge = edges.first(where: { $0.kind == .museUsed && $0.runId == run && $0.to == to }) {
        return edge
      }
    }
    return nil
  }

  @discardableResult
  private mutating func addEdge(_ edge: PageEdge) -> Bool {
    guard !edges.contains(edge) else { return false }
    edges.append(edge)
    return true
  }

  private mutating func prune() {
    let archived = nodes.filter(\.isArchived).sorted(by: Self.closedBefore)
    let gone = Set(archived.prefix(max(0, archived.count - Self.archiveLimit)).map(\.id))
    if !gone.isEmpty { nodes.removeAll { gone.contains($0.id) } }
    let ids = Set(nodes.map(\.id))
    edges.removeAll { !ids.contains($0.from) || !ids.contains($0.to) }
  }

  /// Closed earlier first; equal times fall back to creation order.
  private static func closedBefore(_ a: PageNode, _ b: PageNode) -> Bool {
    (a.updatedAt, Int(a.id.dropFirst()) ?? 0) < (b.updatedAt, Int(b.id.dropFirst()) ?? 0)
  }

  /// The first free slot on the outward rings around `source` (or the centroid of `occupied`),
  /// clockwise from the east. Free means no occupied slot within one slot step in both axes.
  public static func place(near source: CanvasPoint?, occupied: [CanvasPoint]) -> CanvasPoint {
    let anchor =
      source
      ?? (occupied.isEmpty
        ? CanvasPoint(x: 0, y: 0)
        : CanvasPoint(
          x: occupied.map(\.x).reduce(0, +) / Double(occupied.count),
          y: occupied.map(\.y).reduce(0, +) / Double(occupied.count)))
    var ring = 0
    while true {
      for (column, row) in ringOffsets(ring) {
        let spot = CanvasPoint(
          x: anchor.x + Double(column) * slotWidth, y: anchor.y + Double(row) * slotHeight)
        let taken = occupied.contains {
          abs($0.x - spot.x) < slotWidth && abs($0.y - spot.y) < slotHeight
        }
        if !taken { return spot }
      }
      ring += 1
    }
  }

  /// Ring `k` of grid offsets: east, then down the right side, left along the bottom, up the
  /// left side, right along the top and down to just above the start.
  private static func ringOffsets(_ k: Int) -> [(Int, Int)] {
    guard k > 0 else { return [(0, 0)] }
    var offsets: [(Int, Int)] = []
    offsets += (0...k).map { (k, $0) }
    offsets += (1...(2 * k)).map { (k - $0, k) }
    offsets += (1...(2 * k)).map { (-k, k - $0) }
    offsets += (1...(2 * k)).map { (-k + $0, -k) }
    offsets += (1..<k).map { (k, -k + $0) }
    return offsets
  }
}
