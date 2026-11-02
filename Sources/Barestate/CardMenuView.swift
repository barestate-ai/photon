import AppKit
import BarestateCore

/// One row of the card menu: a left-aligned label that presses on Space or Return, moves with the
/// arrow keys and closes the menu on Escape.
@MainActor
private final class CardMenuRow: ChromeButton {
  static let height: CGFloat = 32
  let choice: CardAction
  var onKey: ((NSEvent) -> Bool)?

  init(action: CardAction, width: CGFloat) {
    self.choice = action
    super.init(
      symbol: "circle", label: action.title, side: Self.height, corner: Design.radiusControl)
    frame.size = NSSize(width: width, height: Self.height)
    alignment = .left
    setAccessibilityRole(.menuItem)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// The label, left-aligned with room to breathe.
  override func setText(_ text: String, font: NSFont) {
    super.setText(text, font: font)
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    style.firstLineHeadIndent = 12
    style.headIndent = 12
    attributedTitle = NSAttributedString(
      string: text,
      attributes: [
        .font: font, .foregroundColor: isEnabled ? Design.ink : Design.muted,
        .paragraphStyle: style,
      ])
  }

  override func keyDown(with event: NSEvent) {
    if onKey?(event) != true { super.keyDown(with: event) }
  }
}

/// The menu a right-click on a card opens: Open, Maximize and Close Page for that one page. It is
/// drawn inside the window, never past its edge, over a click-catching layer that closes it.
@MainActor
final class CardMenuView: NSView {
  static let width: CGFloat = 168
  static let inset: CGFloat = 4
  static let margin: CGFloat = 8

  let panel = FlippedView()
  private var rows: [CardMenuRow] = []
  private(set) var node: String?
  /// Chosen: the menu has closed, and this is what the person asked of the page.
  var onChoose: ((CardAction, String) -> Void)?
  /// Closed with nothing chosen.
  var onDismiss: (() -> Void)?

  override var isFlipped: Bool { true }
  var isOpen: Bool { !isHidden }
  var items: [(title: String, enabled: Bool, view: NSView)] {
    rows.map { ($0.choice.title, $0.isEnabled, $0) }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    wantsLayer = true
    panel.wantsLayer = true
    panel.layer?.backgroundColor = Design.surface.cgColor
    panel.layer?.borderColor = Design.line.cgColor
    panel.layer?.borderWidth = 1
    panel.layer?.cornerRadius = Design.radiusPanel
    setAccessibilityElement(false)
    panel.setAccessibilityElement(true)
    panel.setAccessibilityRole(.menu)
    panel.setAccessibilityLabel("Page actions")
    addSubview(panel)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Opens the menu for `node` with its corner at `point` (this view's coordinates), moved in
  /// when that would leave the window. `live` says whether the page has a browser to close.
  func show(for node: String, live: Bool, at point: CGPoint) {
    clear()
    self.node = node
    let width = Self.width * Fonts.scale
    for action in CardAction.allCases {
      let row = CardMenuRow(action: action, width: width - Self.inset * 2)
      row.isEnabled = action.isAvailable(live: live)
      row.setText(action.title, font: Fonts.ui(14))
      row.onClick = { [weak self] in self?.choose(action) }
      row.onKey = { [weak self] in self?.key($0, from: action) ?? false }
      rows.append(row)
    }
    let height = CGFloat(rows.count) * CardMenuRow.height + Self.inset * 2
    for (index, row) in rows.enumerated() {
      row.frame.origin = NSPoint(
        x: Self.inset, y: Self.inset + CGFloat(index) * CardMenuRow.height)
      panel.addSubview(row)
    }
    for (row, next) in zip(rows, rows.dropFirst() + rows.prefix(1)) { row.nextKeyView = next }
    let origin = NSPoint(
      x: max(Self.margin, min(point.x, bounds.width - Self.margin - width)),
      y: max(Self.margin, min(point.y, bounds.height - Self.margin - height)))
    panel.frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
    isHidden = false
    window?.makeFirstResponder(rows.first { $0.isEnabled })
  }

  /// `returningKeys` false when the caller is moving the keyboard itself.
  func dismiss(returningKeys: Bool = true) {
    guard isOpen else { return }
    let hadKeys = rows.contains { window?.firstResponder === $0 }
    clear()
    if hadKeys && returningKeys { onDismiss?() }
  }

  private func clear() {
    for row in rows { row.removeFromSuperview() }
    rows = []
    node = nil
    isHidden = true
  }

  private func choose(_ action: CardAction) {
    guard let node else { return }
    clear()
    onChoose?(action, node)
  }

  private func key(_ event: NSEvent, from action: CardAction) -> Bool {
    let enabled = rows.filter(\.isEnabled)
    guard let index = enabled.firstIndex(where: { $0.choice == action }) else { return false }
    switch event.keyCode {
    case 53:
      dismiss()
    case 125:
      window?.makeFirstResponder(enabled[(index + 1) % enabled.count])
    case 126:
      window?.makeFirstResponder(enabled[(index + enabled.count - 1) % enabled.count])
    default:
      return false
    }
    return true
  }

  /// Everything outside the panel belongs to this view while the menu is open: a click there
  /// closes it, and a right-click goes on to open the menu of the card under it.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isOpen else { return nil }
    let local = convert(point, from: superview)
    guard panel.frame.contains(local) else { return self }
    return panel.hitTest(local) ?? panel
  }

  override func mouseDown(with event: NSEvent) { dismiss() }

  override func rightMouseDown(with event: NSEvent) {
    dismiss()
    guard let root = superview,
      let below = root.hitTest(root.convert(event.locationInWindow, from: nil))
    else { return }
    below.rightMouseDown(with: event)
  }
}
