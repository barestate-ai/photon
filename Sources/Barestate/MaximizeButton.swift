import AppKit
import BarestateCore

/// The ⤢ a hovered or selected card shows beside its "Open" chip: it takes that card's page
/// straight to Full window.
@MainActor
final class MaximizeButton: ChromeButton {
  static let symbol = "arrow.up.left.and.arrow.down.right"
  static let glyph: CGFloat = 11

  let node: String
  /// Whether the control is meant to show: `isHidden` follows once the fade out has ended.
  private(set) var wanted = false

  init(node: String) {
    self.node = node
    super.init(
      symbol: Self.symbol, label: "Maximize", side: NodeCard.maximizeFrame.width,
      glyph: Self.glyph, corner: NodeCard.maximizeFrame.width / 2, tint: Design.petrol)
    restFill = Design.surface
    layer?.borderWidth = 1
    layer?.borderColor = Design.line.cgColor
    isHidden = true
    layer?.opacity = 0
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Whether a person can see it right now.
  var isShown: Bool { !isHiddenOrHasHiddenAncestor && (layer?.opacity ?? 0) > 0 }

  /// The border is the control's own, so the focus ring gives it back when the key moves on.
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    layer?.borderWidth = 1
    layer?.borderColor = Design.line.cgColor
    return resigned
  }

  /// Over the card drawn at `card`, scaled with it.
  func place(over card: CGRect, title: String) {
    let rect = NodeCard.place(NodeCard.maximizeFrame, in: card)
    if frame != rect { frame = rect }
    layer?.cornerRadius = rect.width / 2
    setAccessibilityLabel("Maximize \(title)")
  }

  /// `animated` false takes it away at once: its surface is leaving, so a fade would only keep
  /// the move that hides the surface from settling.
  func show(_ on: Bool, animated: Bool = true) {
    guard on != wanted, let layer else { return }
    wanted = on
    guard animated || on else {
      layer.removeAllAnimations()
      layer.opacity = 0
      isHidden = true
      return
    }
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 0
    let target: Float = on ? 1 : 0
    if on { isHidden = false }
    layer.opacity = target
    MotionLedger.shared.start(
      .buttonHover, target: "maximize:\(node)",
      [
        .init(
          layer: layer, key: "reveal",
          animation: Motion.ease(
            "opacity", from: from, to: target,
            duration: MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.hover))
      ]
    ) { [weak self] finished in
      guard let self, finished, !wanted else { return }
      isHidden = true
    }
  }
}

/// The Maximize controls of one surface: one per card that needs it, made on first use and kept.
@MainActor
final class MaximizeControls {
  struct Target {
    let title: String
    let card: CGRect
  }

  private unowned let host: NSView
  private let press: (String) -> Void
  private let changed: () -> Void
  private(set) var buttons: [String: MaximizeButton] = [:]

  init(host: NSView, press: @escaping (String) -> Void, changed: @escaping () -> Void) {
    self.host = host
    self.press = press
    self.changed = changed
  }

  var shown: [MaximizeButton] { buttons.values.filter(\.isShown).sorted { $0.node < $1.node } }

  /// Shows the controls for `targets`, hides the rest, and drops those of cards that are gone.
  func sync(_ targets: [String: Target], live: Set<String>, animated: Bool = true) {
    var made = false
    for (id, target) in targets {
      let button: MaximizeButton
      if let known = buttons[id] {
        button = known
      } else {
        button = MaximizeButton(node: id)
        button.onClick = { [press] in press(id) }
        host.addSubview(button)
        buttons[id] = button
        made = true
      }
      button.place(over: target.card, title: target.title)
      button.show(true)
    }
    for (id, button) in buttons where targets[id] == nil {
      if live.contains(id) {
        button.show(false, animated: animated)
      } else {
        button.removeFromSuperview()
        buttons[id] = nil
        made = true
      }
    }
    if made { changed() }
  }
}
