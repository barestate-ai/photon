import AppKit
import BarestateCore

/// The stroke every trail is drawn with (frames 777:24 and 777:642): a 1.25 pt dotted line that
/// reads as pencil, copper when Muse made the connection. `zoom` scales the stroke with the
/// cards it joins.
@MainActor
enum Trail {
  static let bow = 12.0

  static func makeLayer() -> CAShapeLayer {
    let line = CAShapeLayer()
    line.fillColor = nil
    line.lineCap = .round
    return line
  }

  static func style(_ line: CAShapeLayer, kind: EdgeKind, zoom: Double = 1) {
    line.strokeColor = (kind == .museUsed ? Design.copper : Design.lineStrong).cgColor
    line.lineWidth = 1.25 * zoom
    line.lineDashPattern = [NSNumber(value: zoom), NSNumber(value: 7 * zoom)]
  }

  static func path(_ route: EdgeRoute, through map: (CGPoint) -> CGPoint = { $0 }) -> CGPath {
    let path = CGMutablePath()
    path.move(to: map(route.start))
    path.addQuadCurve(to: map(route.end), control: map(route.control))
    return path
  }
}
