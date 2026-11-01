import AppKit

/// A borderless button with the design's hover fill and petrol focus ring. The find controls and
/// the command button share it so their keyboard and accessibility handling live in one place.
@MainActor
class ChromeButton: NSButton {
  var onClick: (() -> Void)?
  private let corner: CGFloat
  private var hovering = false { didSet { updateFill(animated: true) } }
  /// What shows when the pointer is elsewhere.
  var restFill: NSColor? { didSet { updateFill() } }

  init(
    symbol: String, label: String, side: CGFloat = 32, glyph: CGFloat = 18,
    corner: CGFloat = 6, tint: NSColor = Design.muted
  ) {
    self.corner = corner
    super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    isBordered = false
    imagePosition = .imageOnly
    imageScaling = .scaleNone
    title = ""
    focusRingType = .none
    contentTintColor = tint
    wantsLayer = true
    layer?.cornerRadius = corner
    target = self
    action = #selector(clicked)
    setSymbol(symbol, glyph: glyph)
    setAccessibilityLabel(label)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func setSymbol(_ symbol: String, glyph: CGFloat = 18) {
    let config = NSImage.SymbolConfiguration(pointSize: glyph, weight: .regular)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  /// A button that reads as text instead of a symbol.
  func setText(_ text: String, font: NSFont) {
    image = nil
    imagePosition = .noImage
    attributedTitle = NSAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: contentTintColor ?? Design.ink])
  }

  @objc private func clicked() {
    onClick?()
  }

  override var isEnabled: Bool {
    didSet { alphaValue = isEnabled ? 1 : 0.4 }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func accessibilityActionNames() -> [NSAccessibility.Action] {
    MainActor.assumeIsolated { isEnabled ? [.press] : [] }
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    performClick(nil)
    return true
  }

  /// Without Full Keyboard Access AppKit leaves buttons out of the Tab loop; the controls must be
  /// reachable by keyboard either way.
  override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
  /// A click presses the button without moving focus off the page; only the keyboard focuses it.
  override var acceptsFirstResponder: Bool {
    isEnabled && NSApp.currentEvent?.type != .leftMouseDown
  }

  override func becomeFirstResponder() -> Bool {
    layer?.borderWidth = 2
    layer?.borderColor = Design.petrol.cgColor
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    layer?.borderWidth = 0
    return super.resignFirstResponder()
  }

  /// Space and Return both press a focused button, as the design's keyboard model says.
  override func keyDown(with event: NSEvent) {
    if [36, 49, 76].contains(event.keyCode) {
      performClick(nil)
    } else if event.keyCode == 48 {
      moveKeyFocus(event)
    } else {
      super.keyDown(with: event)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  /// The press scales the button while the pointer is down, then releases it; `super` runs the
  /// click's tracking loop and returns on mouse up. Reduce Motion drops the scale.
  override func mouseDown(with event: NSEvent) {
    guard isEnabled, !MotionLedger.shared.reduced() else { return super.mouseDown(with: event) }
    scale(to: Motion.pressScale, duration: Motion.press)
    super.mouseDown(with: event)
    scale(to: 1, duration: Motion.pressRelease)
  }

  private func scale(to factor: CGFloat, duration: CFTimeInterval) {
    guard let layer else { return }
    let from = (layer.presentation() ?? layer).transform
    // The backing layer scales about its anchor point; the button should grow from its centre.
    let pivot = CGPoint(
      x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
    var to = CATransform3DMakeScale(factor, factor, 1)
    to.m41 = (factor - 1) * (pivot.x - bounds.midX)
    to.m42 = (factor - 1) * (pivot.y - bounds.midY)
    layer.transform = to
    MotionLedger.shared.start(
      .buttonPress, target: accessibilityLabel() ?? "",
      [
        .init(
          layer: layer, key: "press",
          animation: Motion.ease(
            "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: to),
            duration: duration))
      ])
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  private func updateFill(animated: Bool = false) {
    guard let layer else { return }
    let clear = CGColor(gray: 0, alpha: 0)
    let from = (layer.presentation() ?? layer).backgroundColor ?? clear
    let next = (hovering && isEnabled ? Design.hover : restFill)?.cgColor
    layer.backgroundColor = next
    guard animated, window != nil else { return }
    MotionLedger.shared.start(
      .buttonHover, target: accessibilityLabel() ?? "",
      [
        .init(
          layer: layer, key: "hover",
          animation: Motion.ease(
            "backgroundColor", from: from, to: next ?? clear, duration: Motion.hover))
      ])
  }
}

extension NSView {
  /// Buttons and rows do not run the key-view loop for Tab on their own; this does.
  func moveKeyFocus(_ event: NSEvent) {
    if event.modifierFlags.contains(.shift) {
      window?.selectPreviousKeyView(self)
    } else {
      window?.selectNextKeyView(self)
    }
  }
}
