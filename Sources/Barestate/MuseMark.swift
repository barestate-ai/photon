import AppKit
import BarestateCore

/// The motion of one page's Muse status on one surface (the overview card or the focused page):
/// a copper dot that breathes while the task works or waits for approval, a label that fades when
/// the status changes, and one small moment when the task completes. Everything follows the run
/// state `show` is given; a surface that is not on screen calls `hide`, so nothing keeps running
/// where nobody looks.
@MainActor
final class MuseMark {
  private let surface: String
  private let host: CALayer
  private let dot: CALayer
  private let label: CALayer
  /// The node the surface is showing the status of.
  private var target = ""
  private var state: RunState?
  private var text = ""

  init(surface: String, host: CALayer, dot: CALayer, label: CALayer) {
    self.surface = surface
    self.host = host
    self.dot = dot
    self.label = label
  }

  private var loopId: String { "\(surface):\(target)" }

  /// `animated`: the surface was already on screen, so a change is one the person can watch.
  /// `ring` is where the completion ring stands.
  func show(
    _ next: RunState?, run: String, node: String, text: String, ring: CGRect, animated: Bool
  ) {
    let ledger = MotionLedger.shared
    if node != target {
      hide()
      target = node
    }
    let reduced = ledger.reduced()
    let pulses = (next == .running || next == .waitingApproval) && !reduced
    if pulses {
      ledger.startLoop(
        .musePulse, id: loopId, target: target, runId: run, surface: surface, layer: dot,
        key: "muse.pulse", animation: Self.pulse())
    } else {
      ledger.stopLoop(loopId)
    }
    let before = (state, self.text)
    (state, self.text) = (next, text)
    guard animated, !text.isEmpty, text != before.1 else { return }
    let fade = Motion.ease(
      "opacity", from: 0, to: 1, duration: reduced ? Motion.reducedFade : Motion.fadeSmall)
    guard next == .completed, before.0?.isInProgress == true else {
      ledger.start(
        .museLabel, target: loopId, [.init(layer: label, key: "muse.label", animation: fade)])
      return
    }
    complete(label: fade, ring: ring, reduced: reduced)
  }

  /// The surface left the screen: its loop and any completion go and what it last showed is
  /// forgotten, so coming back replays nothing.
  func hide() {
    MotionLedger.shared.stopLoop(loopId)
    MotionLedger.shared.cancel(.completion, target: loopId)
    (state, text) = (nil, "")
  }

  private static func pulse() -> CABasicAnimation {
    let animation = Motion.ease(
      "opacity", from: 1, to: Motion.pulseLowOpacity, duration: Motion.pulseHalfCycle)
    animation.autoreverses = true
    animation.repeatCount = .infinity
    return animation
  }

  /// Dot springs down from a little larger and a copper ring leaves the card; with Reduce Motion
  /// only the label fades.
  private func complete(label fade: CABasicAnimation, ring frame: CGRect, reduced: Bool) {
    var parts: [MotionLedger.Part] = [.init(layer: label, key: "muse.label", animation: fade)]
    var ring: CALayer?
    if !reduced {
      let outline = CALayer()
      outline.frame = frame
      outline.cornerRadius = Design.radiusControl
      outline.borderWidth = 1.5
      outline.borderColor = Design.copper.cgColor
      outline.opacity = 0
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      host.addSublayer(outline)
      CATransaction.commit()
      ring = outline
      parts =
        [
          .init(
            layer: dot, key: "muse.complete",
            animation: Motion.spring(
              .drop, keyPath: "transform.scale", from: Motion.completionDotScale, to: 1, cap: 0.3)),
          .init(
            layer: outline, key: "muse.ring.fade",
            animation: Motion.ease(
              "opacity", from: 0.5, to: 0, duration: Motion.completionRing)),
          .init(
            layer: outline, key: "muse.ring.grow",
            animation: Motion.ease(
              "transform.scale", from: 1, to: Motion.completionRingScale,
              duration: Motion.completionRing)),
        ] + parts
    }
    MotionLedger.shared.start(.completion, target: loopId, parts) { _ in
      ring?.removeFromSuperlayer()
    }
  }
}
