import CoreGraphics
import Foundation

/// A spring in its physical form. `bounce` is the SwiftUI-style 1 - ζ for an underdamped spring,
/// so the 0.2 ceiling of the motion plan can be checked here instead of by eye.
public struct SpringSpec: Equatable, Sendable {
  public let mass: Double
  public let stiffness: Double
  public let damping: Double

  public init(mass: Double, stiffness: Double, damping: Double) {
    self.mass = mass
    self.stiffness = stiffness
    self.damping = damping
  }

  public var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }
  public var bounce: Double { max(0, 1 - dampingRatio) }

  /// Time for the envelope to fall to 1 % of the first swing.
  public var settlingEstimate: Double {
    let omega = (stiffness / mass).squareRoot()
    return -log(0.01) / (min(dampingRatio, 1) * omega)
  }

  /// The camera between overview and page: critically damped, no overshoot.
  public static let camera = SpringSpec(mass: 1, stiffness: 400, damping: 40)
  /// A pinch released past a zoom limit settling back to it.
  public static let rubberBack = SpringSpec(mass: 1, stiffness: 300, damping: 30)
  /// A dropped card settling: ζ 0.8, under the plan's 0.2 bounce ceiling.
  public static let drop = SpringSpec(mass: 1, stiffness: 420, damping: 33)
}

/// Resistance past a limit: the shown value follows the raw one only a little and never goes
/// further than 12 % beyond it.
public enum RubberBand {
  public static let resistance = 0.12

  public static func shown(_ raw: Double, in range: ClosedRange<Double>) -> Double {
    if raw > range.upperBound {
      let limit = range.upperBound
      return limit * (1 + resistance * tanh((raw - limit) / (resistance * limit)))
    }
    if raw < range.lowerBound {
      let limit = range.lowerBound
      return limit * (1 - resistance * tanh((limit - raw) / (resistance * limit)))
    }
    return raw
  }
}

/// Where a layer standing on `from` must be moved and scaled to stand on `to`: the scale is
/// about its centre, and the translation then carries the centre across.
public struct RectMotion: Equatable, Sendable {
  public let scaleX: Double
  public let scaleY: Double
  public let translateX: Double
  public let translateY: Double

  public init(from: CGRect, to: CGRect) {
    scaleX = to.width / max(from.width, 1e-9)
    scaleY = to.height / max(from.height, 1e-9)
    translateX = to.midX - from.midX
    translateY = to.midY - from.midY
  }

  public var isIdentity: Bool {
    scaleX == 1 && scaleY == 1 && translateX == 0 && translateY == 0
  }
}
