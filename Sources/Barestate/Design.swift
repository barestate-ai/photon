import AppKit
import BarestateCore
import CoreText

/// Photon "Spatial Daylight" tokens from library/design.md. No screen defines its own color.
@MainActor
enum Design {
  static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }

  static let canvas = color(0xFBFAF4)
  static let surface = color(0xFFFEFA)
  static let ink = color(0x091717)
  static let muted = color(0x617068)
  /// Subtitle on a selected row: `muted` is 4.44:1 on `selection`, this is 5.25:1.
  static let mutedOnSelection = color(0x56645D)
  static let line = color(0xDEDCD3)
  static let lineStrong = color(0xC0C4B9)
  static let petrol = color(0x1A6872)
  static let accent = color(0x20808D)
  static let selection = color(0xE7EEEE)
  /// Muse activity only.
  static let copper = color(0xB66A48)
  static let liftBar = color(0x182923)
  static let hover = selection.withAlphaComponent(0.5)

  static let radiusControl: CGFloat = 6
  static let radiusPanel: CGFloat = 12

  /// The original Lift, unmodified: two filled paths in a 100 x 70 box (the Barestate site's
  /// original-lift.svg), drawn at `height` points tall.
  static func liftMark(height: CGFloat) -> NSImage {
    let scale = height / 70
    let image = NSImage(size: NSSize(width: 100 * scale, height: height), flipped: true) { _ in
      let upper = CGMutablePath()
      upper.move(to: CGPoint(x: 8, y: 40))
      upper.addLine(to: CGPoint(x: 16, y: 18))
      upper.addQuadCurve(to: CGPoint(x: 20, y: 15), control: CGPoint(x: 17, y: 16))
      upper.addLine(to: CGPoint(x: 67, y: 1))
      upper.addQuadCurve(to: CGPoint(x: 68, y: 3), control: CGPoint(x: 70, y: 0))
      upper.addLine(to: CGPoint(x: 52, y: 28))
      upper.addQuadCurve(to: CGPoint(x: 48, y: 31), control: CGPoint(x: 51, y: 30))
      upper.closeSubpath()
      let lower = CGMutablePath()
      lower.move(to: CGPoint(x: 7, y: 46))
      lower.addLine(to: CGPoint(x: 79, y: 35))
      lower.addQuadCurve(to: CGPoint(x: 85, y: 38), control: CGPoint(x: 83, y: 34))
      lower.addLine(to: CGPoint(x: 98, y: 65))
      lower.addQuadCurve(to: CGPoint(x: 95, y: 68), control: CGPoint(x: 100, y: 69))
      lower.addLine(to: CGPoint(x: 8, y: 48))
      lower.addQuadCurve(to: CGPoint(x: 7, y: 46), control: CGPoint(x: 4, y: 47))
      lower.closeSubpath()
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.scaleBy(x: scale, y: scale)
      context.setFillColor(liftBar.cgColor)
      context.addPath(upper)
      context.addPath(lower)
      context.fillPath()
      return true
    }
    return image
  }
}

/// Motion vocabulary (research/animation-plan.md). Only these curves, durations and springs are
/// used; every animation starts through `MotionLedger`, which reports it to the test hooks.
@MainActor
enum Motion {
  /// cubic-bezier(0.23, 1, 0.32, 1): the one curve every non-spring animation uses.
  static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

  static let press: CFTimeInterval = 0.10
  static let pressRelease: CFTimeInterval = 0.14
  static let hover: CFTimeInterval = 0.12
  static let hoverBorder: CFTimeInterval = 0.10
  static let fadeSmall: CFTimeInterval = 0.14
  static let crossfade: CFTimeInterval = 0.20
  static let nodeEnter: CFTimeInterval = 0.24
  static let trailDraw: CFTimeInterval = 0.28
  static let trailDelay: CFTimeInterval = 0.08
  static let cameraCap: CFTimeInterval = 0.45
  static let cameraFade: CFTimeInterval = 0.14
  static let overviewFade: CFTimeInterval = 0.16
  static let overviewFadeDelay: CFTimeInterval = 0.10
  static let previewSwapCover: CFTimeInterval = 0.10
  static let columnsFade: CFTimeInterval = 0.16
  static let pickup: CFTimeInterval = 0.12
  static let dropShadow: CFTimeInterval = 0.16
  /// Every Reduce Motion variant; the plan's ceiling is 0.15.
  static let reducedFade: CFTimeInterval = 0.12
  /// The overview toggle's Reduce Motion fades: the toggle is budgeted at 100 ms to settled. Two
  /// 60 Hz frames is the floor; a shorter fade would be a cut.
  static let reducedToggleFade: CFTimeInterval = 0.034
  static let firstRunStagger: CFTimeInterval = 0.06
  static let firstRunText: CFTimeInterval = 0.28
  static let firstRunButton: CFTimeInterval = 0.26
  /// One way of the Muse pulse's breathing; a full cycle is 1.4 s.
  static let pulseHalfCycle: CFTimeInterval = 0.7
  static let pulseLowOpacity: Float = 0.45
  static let completionRing: CFTimeInterval = 0.30
  static let completionDotScale: CGFloat = 1.35
  static let completionRingScale: CGFloat = 1.04
  static let readyIconScale: CGFloat = 0.9
  static let approvalIn: CFTimeInterval = 0.20
  static let approvalOut: CFTimeInterval = 0.14
  /// A takeover or the end of a run leaves with opacity alone.
  static let approvalQuickOut: CFTimeInterval = 0.10
  static let approvalTravel: CGFloat = 8
  /// The phone chip appears unprompted, so it rises in like an approval; it leaves with a fade.
  static let chipIn: CFTimeInterval = 0.20
  static let chipTravel: CGFloat = 8
  static let approvalEnterScale: CGFloat = 0.97
  static let approvalExitScale: CGFloat = 0.98
  /// A safety net for a renderer that does not answer, not the budget: leaving a page waits for
  /// its last look (p50 24 / p95 34 / p99 46 ms, n 120, BENCH.md), so the overview starts from the
  /// fresh image. A toggle is that capture + `reducedToggleFade` + up to two 60 Hz frames (the fade
  /// starts on the next commit and ends on a frame); a capture cut off here costs this + the same
  /// fade and frames: 100 + 34 + 33.3 = 167 ms. Change a term and redo the sums.
  static let previewCaptureTimeout = Duration.milliseconds(100)

  static let enterScale: CGFloat = 0.94
  static let enterTravelFraction: CGFloat = 0.35
  static let pressScale: CGFloat = 0.97
  static let nodePressScale: CGFloat = 0.985
  static let pickupScale: CGFloat = 1.02
  static let pickupShadowOpacity: Float = 0.18
  static let staleOpacity: Float = 0.55
  static let firstRunTravel: CGFloat = 6

  /// A spring as Core Animation takes it, running for its settling time but never past `cap`.
  static func spring(
    _ spec: SpringSpec, keyPath: String, from: Any?, to: Any?, cap: CFTimeInterval = cameraCap
  ) -> CASpringAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = spec.mass
    animation.stiffness = spec.stiffness
    animation.damping = spec.damping
    animation.fromValue = from
    animation.toValue = to
    animation.duration = min(animation.settlingDuration, cap)
    return animation
  }

  /// `from` to `to` on the strong ease-out. `delay` holds the first value until it starts.
  static func ease(
    _ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval, delay: CFTimeInterval = 0
  ) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.timingFunction = easeOut
    if delay > 0 {
      animation.beginTime = CACurrentMediaTime() + delay
      animation.fillMode = .backwards
    }
    return animation
  }

  /// The value the person sees now, else the model value: where an interrupted move restarts.
  static func current(_ layer: CALayer, _ keyPath: String) -> Any? {
    (layer.presentation() ?? layer).value(forKeyPath: keyPath)
  }
}

/// Manrope and Instrument Serif are registered for this process from the app bundle, never from
/// ~/Library/Fonts.
@MainActor
enum Fonts {
  struct Registration {
    let url: URL?
    let registered: Bool
    fileprivate let descriptor: CTFontDescriptor?
  }

  private(set) static var manropeRegistration = Registration(
    url: nil, registered: false, descriptor: nil)
  private(set) static var serifRegistration = Registration(
    url: nil, registered: false, descriptor: nil)

  /// OpenType `wght` variation axis tag.
  static let weightAxis = 2_003_265_652

  /// The text scale chrome text follows (`test.textScale`); canvas and page-preview text do not.
  static var scale: CGFloat = 1

  static func hint(_ size: CGFloat = 12) -> NSFont { NSFont.systemFont(ofSize: size * scale) }

  static func ui(_ size: CGFloat, weight: Double = 400) -> NSFont {
    manrope(size * scale, weight: weight)
  }

  /// Instrument Serif is for the canvas title and headings inside page previews, never a control.
  static func serif(_ size: CGFloat) -> NSFont {
    guard let descriptor = serifRegistration.descriptor else {
      return NSFont.systemFont(ofSize: size)
    }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
  }

  static func registerBundled() {
    manropeRegistration = register("Manrope-Variable.ttf")
    serifRegistration = register("InstrumentSerif-Regular.ttf")
  }

  /// 400 is Regular and 500 is Medium; the design uses no other weight. Falls back to the system
  /// font when registration failed.
  static func manrope(_ size: CGFloat, weight: Double = 400) -> NSFont {
    guard let base = manropeRegistration.descriptor else {
      return NSFont.systemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular)
    }
    let varied = CTFontDescriptorCreateCopyWithVariation(
      base, weightAxis as CFNumber, CGFloat(weight))
    return CTFontCreateWithFontDescriptor(varied, size, nil) as NSFont
  }

  private static func register(_ file: String) -> Registration {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(file)") else {
      return Registration(url: nil, registered: false, descriptor: nil)
    }
    var error: Unmanaged<CFError>?
    let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
    return Registration(url: url, registered: registered, descriptor: descriptors?.first)
  }
}
