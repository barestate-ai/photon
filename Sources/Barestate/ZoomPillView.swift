import AppKit

/// "− 80% +" at the bottom left of the overview: the zoom as a number, with the buttons ⌘− and ⌘=
/// press, and the number itself fitting every page in view as ⌘0 does. Only the overview shows
/// it, because it is a subview of the canvas.
@MainActor
final class ZoomPillView: NSView {
  static let inset: CGFloat = 4

  let out = ChromeButton(symbol: "minus", label: "Zoom out", side: 28, glyph: 14)
  let percent = ChromeButton(
    symbol: "circle", label: "Zoom 100 percent", side: 28, tint: Design.ink)
  let into = ChromeButton(symbol: "plus", label: "Zoom in", side: 28, glyph: 14)
  var onZoomOut: (() -> Void)?
  var onZoomIn: (() -> Void)?
  var onZoomToFit: (() -> Void)?
  private(set) var shown = 100

  override var isFlipped: Bool { true }
  var keyViews: [NSView] { [out, percent, into] }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Design.surface.cgColor
    layer?.borderColor = Design.line.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = Design.radiusPanel
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Zoom")
    setAccessibilityValue("100%")
    percent.setAccessibilityHelp("Fit every page in view, ⌘0")
    out.setAccessibilityHelp("⌘−")
    into.setAccessibilityHelp("⌘=")
    out.onClick = { [weak self] in self?.onZoomOut?() }
    into.onClick = { [weak self] in self?.onZoomIn?() }
    percent.onClick = { [weak self] in self?.onZoomToFit?() }
    for view in [out, percent, into] as [NSView] { addSubview(view) }
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// The buttons and the number follow the text scale; at 1 the pill is 124 x 36.
  func applyTextScale() {
    let s = Fonts.scale
    let (side, gap, width) = (28 * s, Self.inset * s, 60 * s)
    frame.size = NSSize(width: gap * 2 + side * 2 + width, height: side + gap * 2)
    out.frame = NSRect(x: gap, y: gap, width: side, height: side)
    percent.frame = NSRect(x: gap + side, y: gap, width: width, height: side)
    into.frame = NSRect(x: gap + side + width, y: gap, width: side, height: side)
    percent.setText("\(shown)%", font: Fonts.ui(13, weight: 500))
    superview?.needsLayout = true
  }

  /// The label follows the number so a screen reader never reads a stale zoom.
  func show(percent next: Int) {
    guard next != shown else { return }
    shown = next
    percent.setText("\(next)%", font: Fonts.ui(13, weight: 500))
    percent.setAccessibilityLabel("Zoom \(next) percent")
    setAccessibilityValue("\(next)%")
  }
}
