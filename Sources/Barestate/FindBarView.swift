import AppKit

/// Find in page: a small floating bar at the top right of the content area.
@MainActor
final class FindBarView: NSView, NSTextFieldDelegate {
  let field = NSTextField()
  var onQuery: ((String) -> Void)?
  var onStep: ((Bool) -> Void)?
  var onClose: (() -> Void)?
  private(set) var matches = 0
  private(set) var active = 0
  private let count = NSTextField(labelWithString: "")
  private let previous = ChromeButton(
    symbol: "chevron.up", label: "Previous match", side: 32, glyph: 14)
  private let next = ChromeButton(symbol: "chevron.down", label: "Next match", side: 32, glyph: 14)
  private let close = ChromeButton(symbol: "xmark", label: "Close find bar", side: 32, glyph: 14)

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
    wantsLayer = true
    layer?.backgroundColor = Design.surface.cgColor
    layer?.cornerRadius = 8
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.12
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    isHidden = true

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.textColor = Design.ink
    field.delegate = self
    field.setAccessibilityRole(.textField)
    field.setAccessibilityLabel("Find in page")
    count.textColor = Design.muted
    count.alignment = .right
    previous.onClick = { [weak self] in self?.onStep?(false) }
    next.onClick = { [weak self] in self?.onStep?(true) }
    close.onClick = { [weak self] in self?.onClose?() }
    for view in [field, count, previous, next, close] as [NSView] { addSubview(view) }

    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// The controls in Tab order; hidden ones are skipped by the key loop.
  var keyViews: [(id: String, view: NSView)] {
    [("findField", field), ("findPrevious", previous), ("findNext", next), ("findClose", close)]
  }

  /// The bar's width at the text scale; the owner narrows it to fit a small window.
  static var width: CGFloat { 348 * Fonts.scale }
  static var height: CGFloat { 48 * Fonts.scale }

  func applyTextScale() {
    field.font = Fonts.ui(14)
    field.placeholderAttributedString = NSAttributedString(
      string: "Find in page",
      attributes: [.font: Fonts.ui(14), .foregroundColor: Design.muted])
    count.font = Fonts.ui(12)
    fit(width: Self.width)
  }

  /// Lays the bar out in `width`: the buttons keep their size, the field gives way.
  func fit(width: CGFloat) {
    let s = Fonts.scale
    let side = 32 * s
    frame.size = NSSize(width: width, height: Self.height)
    for button in [previous, next, close] { button.frame.size = NSSize(width: side, height: side) }
    close.frame.origin = NSPoint(x: width - 8 - side, y: 8 * s)
    next.frame.origin = NSPoint(x: close.frame.minX - 36 * s, y: 8 * s)
    previous.frame.origin = NSPoint(x: next.frame.minX - side, y: 8 * s)
    let countWidth = 64 * s
    count.frame = NSRect(
      x: previous.frame.minX - 6 - countWidth, y: 16 * s, width: countWidth, height: 17 * s)
    field.frame = NSRect(
      x: 16, y: 14 * s, width: max(0, count.frame.minX - 4 - 16), height: 20 * s)
  }

  var text: String { field.stringValue }

  var hasFocus: Bool { (window?.firstResponder as? NSText)?.delegate === field }

  func show() {
    isHidden = false
    window?.makeFirstResponder(field)
    field.selectText(nil)
  }

  func hide() {
    isHidden = true
    update(matches: 0, active: 0)
  }

  func update(matches: Int, active: Int) {
    self.matches = matches
    self.active = active
    count.stringValue = text.isEmpty ? "" : (matches == 0 ? "0 of 0" : "\(active) of \(matches)")
  }

  func controlTextDidChange(_ notification: Notification) {
    onQuery?(field.stringValue)
  }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
  ) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default:
      return false
    }
  }
}
