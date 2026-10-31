import CoreGraphics
import Foundation

extension PageNode {
  /// The card (preview) is 220 x 184; the caption below it fills the rest of the 230 pt slot group.
  public static let cardHeight = 184.0

  /// Card plus caption, in canvas coordinates.
  public var frame: CGRect {
    CGRect(
      x: x - PageGraph.nodeWidth / 2, y: y - PageGraph.nodeHeight / 2,
      width: PageGraph.nodeWidth, height: PageGraph.nodeHeight)
  }

  public var cardFrame: CGRect {
    CGRect(x: frame.minX, y: frame.minY, width: PageGraph.nodeWidth, height: Self.cardHeight)
  }
}

/// Camera maths. A viewport shows the canvas point `(cx, cy)` at the centre of a view `size`
/// points across, magnified by `zoom`; screen coordinates have their origin at the top left.
extension Viewport {
  public func screen(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: (point.x - cx) * zoom + size.width / 2, y: (point.y - cy) * zoom + size.height / 2)
  }

  public func canvas(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: (point.x - size.width / 2) / zoom + cx, y: (point.y - size.height / 2) / zoom + cy)
  }

  public func visibleRect(in size: CGSize) -> CGRect {
    CGRect(
      x: cx - size.width / 2 / zoom, y: cy - size.height / 2 / zoom, width: size.width / zoom,
      height: size.height / zoom)
  }

  /// Content follows the scroll delta: scrolling down by `delta` moves the centre up the canvas.
  public func panned(byScreen delta: CGSize) -> Viewport {
    Viewport(cx: cx - delta.width / zoom, cy: cy - delta.height / zoom, zoom: zoom)
  }

  /// Zooms by `factor` (clamped to the zoom range) with the canvas point under `point` staying
  /// under it. A factor that is not a finite number leaves the zoom alone.
  public func zoomed(by factor: Double, around point: CGPoint, in size: CGSize) -> Viewport {
    let scale = factor.isFinite ? max(factor, 0.01) : 1
    let target = Viewport(cx: cx, cy: cy, zoom: zoom * scale).zoom
    let anchor = canvas(point, in: size)
    return Viewport(
      cx: anchor.x - (point.x - size.width / 2) / target,
      cy: anchor.y - (point.y - size.height / 2) / target, zoom: target)
  }

  /// The smallest pan that brings `rect` inside the view with `margin` to spare; a rect larger
  /// than the view on one axis is centred on that axis.
  public func revealing(_ rect: CGRect, in size: CGSize, margin: Double) -> Viewport {
    let visible = visibleRect(in: size).insetBy(dx: margin / zoom, dy: margin / zoom)
    func shift(_ low: Double, _ high: Double, _ visibleLow: Double, _ visibleHigh: Double)
      -> Double
    {
      if high - low > visibleHigh - visibleLow {
        return (low + high) / 2 - (visibleLow + visibleHigh) / 2
      }
      if low < visibleLow { return low - visibleLow }
      if high > visibleHigh { return high - visibleHigh }
      return 0
    }
    return Viewport(
      cx: cx + shift(rect.minX, rect.maxX, visible.minX, visible.maxX),
      cy: cy + shift(rect.minY, rect.maxY, visible.minY, visible.maxY), zoom: zoom)
  }

  /// Every rect inside the view with `margin` around the group, centred, magnified no more than
  /// `maxZoom`; nothing to show is the origin at 1.
  public static func fitting(
    _ rects: [CGRect], in size: CGSize, margin: Double, maxZoom: Double = zoomRange.upperBound
  ) -> Viewport {
    guard let first = rects.first else { return Viewport() }
    let box = rects.dropFirst().reduce(first) { $0.union($1) }
    let zoom = min(
      (size.width - 2 * margin) / box.width, (size.height - 2 * margin) / box.height, maxZoom)
    return Viewport(cx: box.midX, cy: box.midY, zoom: zoom)
  }
}

public enum Direction: Sendable {
  case left, right, up, down
}

public enum CanvasNavigation {
  /// The nearest node whose centre lies within 45 degrees of `direction` from `from`'s centre;
  /// every node is within 45 degrees of some axis, so arrows reach all of them.
  public static func nearest(from id: String, toward direction: Direction, in nodes: [PageNode])
    -> String?
  {
    guard let origin = nodes.first(where: { $0.id == id }) else { return nil }
    var best: (distance: Double, id: String)?
    for node in nodes where node.id != id {
      let (dx, dy) = (node.x - origin.x, node.y - origin.y)
      let (along, across): (Double, Double) =
        switch direction {
        case .right: (dx, dy)
        case .left: (-dx, dy)
        case .down: (dy, dx)
        case .up: (-dy, dx)
        }
      guard along > 0, along >= abs(across) else { continue }
      let distance = along * along + across * across
      if best == nil || (distance, node.id) < (best!.distance, best!.id) {
        best = (distance, node.id)
      }
    }
    return best?.id
  }
}

/// A trail between two cards: a quadratic curve from the facing edge midpoint of one to the other,
/// bowed `bow` points off the straight line. `sideways` joins the left or right edges even when
/// the cards sit further apart vertically than across.
public struct EdgeRoute: Equatable, Sendable {
  public let start: CGPoint
  public let control: CGPoint
  public let end: CGPoint

  public static func make(
    from source: CGRect, to target: CGRect, bow: Double, sideways: Bool = false
  ) -> EdgeRoute {
    let (dx, dy) = (target.midX - source.midX, target.midY - source.midY)
    let (start, end): (CGPoint, CGPoint)
    if sideways || abs(dx) >= abs(dy) {
      let sign = dx >= 0 ? 1.0 : -1.0
      start = CGPoint(x: sign > 0 ? source.maxX : source.minX, y: source.midY)
      end = CGPoint(x: sign > 0 ? target.minX : target.maxX, y: target.midY)
    } else {
      let sign = dy >= 0 ? 1.0 : -1.0
      start = CGPoint(x: source.midX, y: sign > 0 ? source.maxY : source.minY)
      end = CGPoint(x: target.midX, y: sign > 0 ? target.minY : target.maxY)
    }
    let (ex, ey) = (end.x - start.x, end.y - start.y)
    let length = max((ex * ex + ey * ey).squareRoot(), 1e-9)
    // The normal is the direction turned a quarter, so a pair bows the same way every time.
    let control = CGPoint(
      x: (start.x + end.x) / 2 - ey / length * bow, y: (start.y + end.y) / 2 + ex / length * bow)
    return EdgeRoute(start: start, control: control, end: end)
  }
}
