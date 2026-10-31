import AppKit

/// "Search or do anything ⌘T": the only visible way in besides the shortcut. A click does exactly
/// what ⌘T does; the owner wires `onClick`.
@MainActor
final class CommandButton: ChromeButton {
  static var width: CGFloat { 288 * Fonts.scale }
  static var height: CGFloat { 48 * Fonts.scale }

  private let glyph = NSImageView()
  private let label = NSTextField(labelWithString: "Search or do anything")
  private let chip = FlippedView()
  private let key = NSTextField(labelWithString: "⌘T")

  override var isFlipped: Bool { true }

  init() {
    super.init(
      symbol: "magnifyingglass", label: "Search or do anything", side: Self.height, glyph: 20,
      corner: Design.radiusPanel, tint: Design.ink)
    image = nil
    restFill = Design.surface
    setAccessibilityHelp("⌘T")
    layer?.borderWidth = 1
    layer?.borderColor = Design.line.cgColor
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.08
    layer?.shadowRadius = 16
    layer?.shadowOffset = CGSize(width: 0, height: -12)

    glyph.contentTintColor = Design.ink
    label.textColor = Design.ink
    chip.wantsLayer = true
    chip.layer?.backgroundColor = Design.canvas.cgColor
    chip.layer?.borderColor = Design.line.cgColor
    chip.layer?.borderWidth = 1
    chip.layer?.cornerRadius = Design.radiusControl
    key.textColor = Design.muted
    chip.addSubview(key)
    for view in [glyph, label, chip] as [NSView] {
      view.setAccessibilityElement(false)
      addSubview(view)
    }
    applyTextScale()
  }

  /// Sizes and fonts follow the text scale; at 1 they are the design's 288 x 48.
  func applyTextScale() {
    let s = Fonts.scale
    frame.size = NSSize(width: Self.width, height: Self.height)
    glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 18 * s, weight: .regular))
    glyph.frame = NSRect(x: 12 * s, y: 12 * s, width: 24 * s, height: 24 * s)
    label.font = Fonts.ui(14)
    label.frame = NSRect(x: 48 * s, y: 14 * s, width: 180 * s, height: 20 * s)
    key.font = Fonts.hint()
    key.sizeToFit()
    chip.frame = NSRect(x: Self.width - 12 * s - 32 * s, y: 12 * s, width: 32 * s, height: 24 * s)
    key.frame.origin = NSPoint(
      x: (chip.frame.width - key.frame.width) / 2, y: (chip.frame.height - key.frame.height) / 2)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// The children are decoration: any click inside is a click on the button.
  override func hitTest(_ point: NSPoint) -> NSView? {
    isHiddenOrHasHiddenAncestor || !frame.contains(point) ? nil : self
  }

  var labelFont: NSFont? { label.font }
  var keyFont: NSFont? { key.font }
  var hintText: String { key.stringValue }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    layer?.borderWidth = 1
    layer?.borderColor = Design.line.cgColor
    return resigned
  }
}
