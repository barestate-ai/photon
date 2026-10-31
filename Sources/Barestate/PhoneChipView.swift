import AppKit

/// "Phone connected" with Disconnect, in the identity row's right corner while a phone has a
/// session open. It sits on the canvas and over a focused page's margin, never on the page.
@MainActor
final class PhoneChipView: NSView {
  let disconnect = ApprovalButton(title: "Disconnect", tone: Design.ink)
  private let dot = NSView()
  private let label = NSTextField(labelWithString: "Phone connected")
  private(set) var shown = false

  private static let pad: CGFloat = 8
  private static let gap: CGFloat = 8

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Design.surface.cgColor
    layer?.borderColor = Design.line.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = Design.radiusPanel
    dot.wantsLayer = true
    dot.layer?.backgroundColor = Design.accent.cgColor
    dot.layer?.cornerRadius = 4
    label.textColor = Design.ink
    label.setAccessibilityElement(false)
    dot.setAccessibilityElement(false)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Phone connected")
    for view in [dot, label, disconnect] as [NSView] { addSubview(view) }
    isHidden = true
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func applyTextScale() {
    label.font = Fonts.ui(13, weight: 500)
    label.sizeToFit()
    disconnect.applyTextScale()
    let height = disconnect.frame.height + 2 * Self.pad
    let labelX = Self.pad + 8 + Self.gap + 4
    disconnect.frame.origin = NSPoint(x: labelX + label.frame.width + Self.gap, y: Self.pad)
    frame.size = NSSize(width: disconnect.frame.maxX + Self.pad, height: height)
    dot.frame = NSRect(x: Self.pad + 4, y: ((height - 8) / 2).rounded(), width: 8, height: 8)
    label.frame.origin = NSPoint(x: labelX, y: ((height - label.frame.height) / 2).rounded())
  }

  /// Rises in with the fade of an approval card; leaves with the fade alone. Reduce Motion is the
  /// fade only, shorter.
  func setShown(_ on: Bool, animated: Bool) {
    guard on != shown, let layer else { return }
    shown = on
    layer.removeAllAnimations()
    layer.opacity = on ? 1 : 0
    layer.transform = CATransform3DIdentity
    if on { isHidden = false }
    guard animated else {
      isHidden = !on
      return
    }
    let reduced = MotionLedger.shared.reduced()
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "phoneChip.fade",
        animation: Motion.ease(
          "opacity", from: on ? 0 : 1, to: on ? 1 : 0,
          duration: reduced ? Motion.reducedFade : on ? Motion.chipIn : Motion.fadeSmall))
    ]
    if on, !reduced {
      parts.append(
        .init(
          layer: layer, key: "phoneChip.rise",
          animation: Motion.ease(
            "transform",
            from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, Motion.chipTravel, 0)),
            to: NSValue(caTransform3D: CATransform3DIdentity), duration: Motion.chipIn)))
    }
    MotionLedger.shared.start(.phoneChip, target: "phone", parts) { [weak self] _ in
      if self?.shown == false { self?.isHidden = true }
    }
  }
}
