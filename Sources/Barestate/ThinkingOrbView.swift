import AppKit
import BarestateCore

/// The thinking orb beside the command button: six copper dots orbiting while Muse waits for the
/// model, tighter and faster while an action runs. With Reduce Motion the dots stand still; hidden,
/// the orb has no animating layers. Inspired by libraries.dev/orbs, written on Core Animation.
@MainActor
final class ThinkingOrbView: NSView {
  static let size: CGFloat = 20
  private static let dotCount = 6

  private let ring = CALayer()
  private var dots: [CAShapeLayer] = []
  /// The run the orb follows, empty when hidden. `working` is the variant: an action in flight.
  private(set) var runId = ""
  private(set) var working = false

  var shown: Bool { !runId.isEmpty }
  var spinning: Bool { ring.animation(forKey: "orb.spin") != nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    setAccessibilityElement(false)
    ring.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
    layer?.addSublayer(ring)
    for i in 0..<Self.dotCount {
      let dot = CAShapeLayer()
      let angle = CGFloat(i) * 2 * .pi / CGFloat(Self.dotCount)
      dot.position = CGPoint(
        x: Self.size / 2 + 6.5 * cos(angle), y: Self.size / 2 + 6.5 * sin(angle))
      dot.fillColor = Design.copper.cgColor
      ring.addSublayer(dot)
      dots.append(dot)
    }
    styleDots()
    layer?.opacity = 0
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Thinking leaves a trailing tail; working dots all lead. Restyling is instant, including the
  /// switch to the working variant: an implicit opacity animation would bypass the ledger.
  private func styleDots() {
    let diameter: CGFloat = working ? 3.6 : 3
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (i, dot) in dots.enumerated() {
      dot.path = CGPath(
        ellipseIn: CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter),
        transform: nil)
      dot.opacity = working ? 1 : 1 - Float(i) * 0.14
    }
    CATransaction.commit()
  }

  private var loopId: String { "orb:\(runId):\(working ? "working" : "thinking")" }

  /// `animated` is false while the camera moves: the orb appears with the settling frame instead.
  func show(run: String, working: Bool, animated: Bool) {
    let entered = !shown
    if entered {
      runId = run
      self.working = working
      styleDots()
      isHidden = false
      fade(to: 1, animated: animated)
    } else if run != runId || working != self.working {
      MotionLedger.shared.stopLoop(loopId, settle: false)
      runId = run
      self.working = working
      styleDots()
    }
    orbit()
  }

  func hide(animated: Bool) {
    guard shown else { return }
    MotionLedger.shared.stopLoop(loopId, settle: false)
    runId = ""
    fade(to: 0, animated: animated) { [weak self] in
      guard let self, !shown else { return }
      isHidden = true
    }
  }

  private func fade(to target: Float, animated: Bool, then done: (() -> Void)? = nil) {
    guard let layer else { return }
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 0
    layer.opacity = target
    guard animated, from != target else {
      MotionLedger.shared.cancel(.thinkingOrb)
      done?()
      return
    }
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.fadeSmall
    MotionLedger.shared.start(
      .thinkingOrb, target: "orb",
      [
        .init(
          layer: layer, key: "orb.fade",
          animation: Motion.ease("opacity", from: from, to: target, duration: duration))
      ]
    ) { finished in
      if finished { done?() }
    }
  }

  /// The one looping animation: the dots' shared orbit, linear, until the run leaves. Absent
  /// with Reduce Motion.
  private func orbit() {
    guard shown, !MotionLedger.shared.reduced() else {
      if shown { MotionLedger.shared.stopLoop(loopId, settle: false) }
      return
    }
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = -2 * Double.pi
    animation.duration = working ? Motion.orbWork : Motion.orbThink
    animation.timingFunction = Motion.linear
    animation.repeatCount = .infinity
    MotionLedger.shared.startLoop(
      .thinkingOrb, id: loopId, target: "orb", runId: runId, surface: "chrome", layer: ring,
      key: "orb.spin", animation: animation)
  }
}
