import AppKit

/// "Your trail" and "Muse" with a sample of each line, bottom left. An entry is there only while
/// edges of its kind exist.
@MainActor
final class LegendView: NSView {
  @MainActor
  enum Item: CaseIterable {
    case yourTrail, muse

    var label: String { self == .yourTrail ? "Your trail" : "Muse" }
    var color: NSColor { self == .yourTrail ? Design.lineStrong : Design.copper }
    var width: CGFloat { self == .yourTrail ? 100 : 88 }
  }

  static var height: CGFloat { 24 * Fonts.scale }
  private(set) var items: [Item] = []

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    setAccessibilityElement(true)
    setAccessibilityEnabled(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Legend")
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  func show(_ next: [Item], force: Bool = false) {
    guard next != items || force else { return }
    items = next
    setAccessibilityValue(next.map(\.label).joined(separator: ", "))
    for view in subviews { view.removeFromSuperview() }
    var x: CGFloat = 0
    for item in next {
      let swatch = LegendSwatch(color: item.color)
      swatch.frame = NSRect(x: x, y: (Self.height - 16) / 2, width: 24, height: 16)
      let label = NSTextField(labelWithString: item.label)
      label.font = Fonts.ui(12)
      label.textColor = Design.muted
      label.sizeToFit()
      label.frame.origin = NSPoint(x: x + 32, y: (Self.height - label.frame.height) / 2)
      swatch.setAccessibilityElement(false)
      label.setAccessibilityElement(false)
      addSubview(swatch)
      addSubview(label)
      x += max(item.width, 32 + label.frame.width) + 16
    }
    frame.size = NSSize(width: max(0, x - 16), height: Self.height)
    isHidden = next.isEmpty
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LegendSwatch: NSView {
  override var isFlipped: Bool { true }

  init(color: NSColor) {
    super.init(frame: .zero)
    wantsLayer = true
    let line = CAShapeLayer()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 8))
    path.addLine(to: CGPoint(x: 24, y: 8))
    line.path = path
    line.strokeColor = color.cgColor
    line.lineWidth = 1.25
    line.lineCap = .round
    line.lineDashPattern = [1, 7]
    layer?.addSublayer(line)
  }

  required init?(coder: NSCoder) { fatalError("not used") }
}
