import AppKit
import BarestateCore

/// Under the focused page: its title, then the host and how far to trust it. Removing the address
/// bar must never hide which site is active.
@MainActor
final class PageCaptionView: NSView {
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  private(set) var shown: PageCaption?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    applyTextScale()
    title.textColor = Design.ink
    title.lineBreakMode = .byTruncatingTail
    detail.textColor = Design.muted
    detail.lineBreakMode = .byClipping
    addSubview(title)
    addSubview(detail)
    isHidden = true
    setAccessibilityElement(true)
    setAccessibilityEnabled(true)
    title.setAccessibilityElement(false)
    detail.setAccessibilityElement(false)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Page")
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var titleText: String { title.stringValue }
  var detailText: String { detail.stringValue }
  /// False when the host line is clipped.
  var detailFits: Bool { detail.attributedStringValue.size().width <= detail.frame.width + 0.5 }

  func show(_ caption: PageCaption?) {
    guard caption != shown else { return }
    shown = caption
    isHidden = caption == nil
    title.stringValue = caption?.title ?? ""
    detail.stringValue = caption.map { "\($0.host) · \($0.security.rawValue)" } ?? ""
    setAccessibilityLabel(caption.map { $0.title.isEmpty ? "Page" : $0.title } ?? "Page")
    setAccessibilityValue(detail.stringValue)
    needsLayout = true
  }

  func applyTextScale() {
    title.font = Fonts.ui(14)
    detail.font = Fonts.ui(12)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let s = Fonts.scale
    title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20 * s)
    detail.frame = NSRect(x: 0, y: 20 * s, width: bounds.width, height: 18 * s)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
