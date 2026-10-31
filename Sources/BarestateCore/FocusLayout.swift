import CoreGraphics

/// Where the focused page sits in its context (frame 777:642), in window points with the origin at
/// the top left. The live page fills `card`; the pages it is connected to stand in two columns
/// beside it, and below 1100 pt wide the columns go and the page fills the window.
public struct FocusLayout: Equatable, Sendable {
  public static let collapseWidth = 1100.0
  static let cardRatio = 632.0 / 532.0
  static let margin = 24.0
  static let collapsedTop = 96.0
  static let expandedTop = 208.0
  static let captionHeight = 38.0
  static let columnTop = 128.0
  static let columnGap = 24.0

  public let card: CGRect
  public let caption: CGRect
  public let columns: Bool
  /// One slot per neighbour that fits, top to bottom; each is the card plus its caption.
  public let left: [CGRect]
  public let right: [CGRect]

  /// `scale` is the text scale: the caption and the command button under the card grow with it.
  public static func make(
    size: CGSize, left wantLeft: Int, right wantRight: Int, scale: Double = 1
  ) -> FocusLayout {
    let wide = size.width >= collapseWidth
    let columns = wide && wantLeft + wantRight > 0
    let captionHeight = captionHeight * scale
    let belowCard = 4 + captionHeight + (16.0 + 48.0 * scale + 8.0)
    let width: Double
    let height: Double
    let x: Double
    let top: Double
    if wide {
      width = min((0.439 * size.width).rounded(), 900)
      height = min((width / cardRatio).rounded(), size.height - belowCard - collapsedTop)
      x = columns ? (0.325 * size.width).rounded() : ((size.width - width) / 2).rounded()
      top = min(expandedTop, size.height - belowCard - height)
    } else {
      width = size.width - margin * 2
      height = size.height - belowCard - collapsedTop
      x = margin
      top = collapsedTop
    }
    let card = CGRect(x: x, y: top, width: max(0, width), height: max(0, height))
    let caption = CGRect(
      x: card.minX, y: card.maxY + 4, width: card.width, height: captionHeight)
    guard columns else {
      return FocusLayout(card: card, caption: caption, columns: false, left: [], right: [])
    }
    let leftWidth = min(max((0.175 * size.width).rounded(), 168), 280)
    let rightWidth = min(max((0.139 * size.width).rounded(), 144), 224)
    let inset = size.width >= 1200 ? 48.0 : 32.0
    let floor = size.height - 16 - 48
    return FocusLayout(
      card: card, caption: caption, columns: true,
      left: slots(wantLeft, x: inset, width: leftWidth, floor: floor),
      right: slots(
        wantRight, x: size.width - inset - 12 - rightWidth, width: rightWidth, floor: floor))
  }

  /// A neighbour is drawn like an overview card, scaled to the column's width.
  private static func slots(_ count: Int, x: Double, width: Double, floor: Double) -> [CGRect] {
    let height = (PageGraph.nodeHeight * width / PageGraph.nodeWidth).rounded()
    var slots: [CGRect] = []
    var y = columnTop
    while slots.count < count, y + height <= floor {
      slots.append(CGRect(x: x, y: y, width: width, height: height))
      y += height + columnGap
    }
    return slots
  }
}

extension PageGraph {
  /// The pages joined to `id` by a recorded edge in either direction, newest edge first, on the
  /// side of the canvas where each lies.
  public func context(of id: String) -> (left: [PageNode], right: [PageNode]) {
    guard let focus = nodes.first(where: { $0.id == id }) else { return ([], []) }
    var seen = Set<String>()
    let neighbours = edges.reversed().compactMap { edge -> PageNode? in
      let other = edge.from == id ? edge.to : (edge.to == id ? edge.from : nil)
      guard let other, seen.insert(other).inserted else { return nil }
      return nodes.first { $0.id == other }
    }
    return (neighbours.filter { $0.x < focus.x }, neighbours.filter { $0.x >= focus.x })
  }
}
