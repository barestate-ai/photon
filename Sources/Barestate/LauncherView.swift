import AppKit
import BarestateCore

/// The ⌘T launcher: a panel over the whole window. The view fills the window so the page and the
/// canvas behind it take no click; the panel is placed by `LauncherGeometry`.
@MainActor
final class LauncherView: NSView, NSTextFieldDelegate {
  var onQuery: ((String) -> Void)?
  var onMove: ((Int) -> Void)?
  /// A row id, or nil for the active row.
  var onChoose: ((String?) -> Void)?
  var onFocusRow: ((String) -> Void)?
  var onDismiss: (() -> Void)?
  let field = NSTextField()
  let escHint = KeyChip("Esc", width: 32)
  let keyChips = [KeyChip("↑", width: 32), KeyChip("↓", width: 32), KeyChip("Enter", width: 48)]
  let keyLabels = [NSTextField(labelWithString: "Choose"), NSTextField(labelWithString: "Open")]
  let origin = NSTextField(labelWithString: "")
  /// The footer's left side: the active page's host and how far to trust it.
  private(set) var footerCaption: PageCaption?
  private(set) var pageIncluded = false
  private(set) var scope = LauncherScope.all
  private let ambient = NSView()
  let panel = FlippedView()
  private let searchIcon = NSImageView()
  private let list = FlippedView()
  private var rowViews: [String: LauncherRowView] = [:]
  private var headers: [String: NSTextField] = [:]
  private var rows: [LauncherRow] = []
  private var activeId: String?
  private var scrollOffset = 0.0
  private var rowHeights: [String: Double] = [:]
  private var contentHeight = 0.0

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    ambient.wantsLayer = true
    ambient.layer?.backgroundColor = Design.surface.cgColor
    ambient.layer?.cornerRadius = Design.radiusPanel
    ambient.layer?.shadowColor = NSColor.black.cgColor
    ambient.layer?.shadowOpacity = 0.08
    ambient.layer?.shadowRadius = 16
    ambient.layer?.shadowOffset = CGSize(width: 0, height: -12)
    panel.wantsLayer = true
    panel.layer?.backgroundColor = Design.surface.cgColor
    panel.layer?.cornerRadius = Design.radiusPanel
    panel.layer?.borderWidth = LauncherGeometry.border
    panel.layer?.borderColor = Design.line.cgColor
    panel.layer?.shadowColor = NSColor.black.cgColor
    panel.layer?.shadowOpacity = 0.04
    panel.layer?.shadowRadius = 2
    panel.layer?.shadowOffset = CGSize(width: 0, height: -2)
    panel.setAccessibilityElement(true)
    panel.setAccessibilityEnabled(true)
    panel.setAccessibilityRole(.group)
    panel.setAccessibilityLabel("Command launcher")
    list.wantsLayer = true
    list.layer?.masksToBounds = true

    searchIcon.imageScaling = .scaleNone
    searchIcon.contentTintColor = Design.ink
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.textColor = Design.ink
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.cell?.usesSingleLineMode = true
    field.delegate = self
    field.setAccessibilityRole(.textField)
    field.setAccessibilityLabel("Search, visit a website, or start a task")
    for label in keyLabels + [origin] { label.textColor = Design.muted }
    origin.lineBreakMode = .byTruncatingTail
    addSubview(ambient)
    addSubview(panel)
    for view in [searchIcon, field, escHint, list, origin] as [NSView] { panel.addSubview(view) }
    for view in keyChips as [NSView] + keyLabels { panel.addSubview(view) }
    setScope(.all)
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var isOpen: Bool { !isHidden }
  /// The rows on show match the model, so a row that changes now is one the person watches change.
  private var settled = false

  func rowView(id: String) -> LauncherRowView? { rowViews[id] }

  /// The right side of the footer, as `test.ui` reports it.
  var hints: [String] {
    [keyChips[0].label.stringValue, keyChips[1].label.stringValue, keyLabels[0].stringValue]
      + [keyChips[2].label.stringValue, keyLabels[1].stringValue]
  }

  var placeholder: String { field.placeholderAttributedString?.string ?? "" }

  /// Whether a row is at least partly inside the scrolling list.
  func isShown(_ id: String) -> Bool {
    guard let view = rowViews[id] else { return false }
    return view.frame.maxY > scrollOffset && view.frame.minY < scrollOffset + list.frame.height
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if isOpen { layoutPanel() }
  }

  // MARK: Showing

  func show(query: String) {
    if field.stringValue != query { field.stringValue = query }
    isHidden = false
    layoutPanel()
  }

  func hide() {
    isHidden = true
    settled = false
  }

  /// Everything the panel shows comes from the model, so one call redraws it.
  func render(rows: [LauncherRow], activeId: String?, pageIncluded: Bool) {
    self.rows = rows
    self.activeId = activeId
    self.pageIncluded = pageIncluded
    updateOrigin()
    layoutPanel()
    settled = isOpen
    NSAccessibility.post(element: panel, notification: .layoutChanged)
  }

  func setOrigin(_ caption: PageCaption?) {
    guard caption != footerCaption else { return }
    footerCaption = caption
    updateOrigin()
    if isOpen { layoutPanel() }
  }

  func setScope(_ scope: LauncherScope) {
    self.scope = scope
    let text =
      switch scope {
      case .all: "Search, visit a website, or start a task"
      case .history: "Search your history"
      case .web: "Search the web"
      }
    field.placeholderAttributedString = NSAttributedString(
      string: text,
      attributes: [.font: Fonts.ui(19), .foregroundColor: Design.muted])
  }

  /// With no page the footer names the canvas, whose default title is "Your pages".
  private func updateOrigin() {
    let text = NSMutableAttributedString()
    func add(_ string: String, _ color: NSColor) {
      text.append(
        NSAttributedString(
          string: string, attributes: [.font: Fonts.ui(12), .foregroundColor: color]))
    }
    if let caption = footerCaption {
      add(caption.host, Design.ink)
      add(" · \(caption.security.rawValue)", Design.muted)
    } else {
      add("Your pages", Design.ink)
    }
    if pageIncluded { add(" · Current page included", Design.muted) }
    origin.attributedStringValue = text
  }

  func focusField(selectAll: Bool = false) {
    guard let window else { return }
    window.makeFirstResponder(field)
    if let editor = field.currentEditor() {
      let length = (field.stringValue as NSString).length
      editor.selectedRange =
        selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
    }
  }

  // MARK: Layout

  private func layoutPanel() {
    let s = Double(Fonts.scale)
    let sections = LauncherSection.group(rows)
    let inner = LauncherGeometry.panelWidth(window: bounds.size) - LauncherGeometry.padding * 2
    syncRows(sections, width: inner)
    let full =
      Double(sections.count) * LauncherGeometry.sectionHeight * s + rowHeights.values.reduce(0, +)
    contentHeight = full
    let (frame, shown) = LauncherGeometry.panel(window: bounds.size, listHeight: full, scale: s)
    panel.frame = frame
    ambient.frame = frame
    ambient.layer?.shadowPath = CGPath(
      roundedRect: ambient.bounds.insetBy(dx: 10, dy: 10), cornerWidth: Design.radiusPanel,
      cornerHeight: Design.radiusPanel, transform: nil)

    let width = frame.width
    let fieldTop = LauncherGeometry.border + LauncherGeometry.padding
    let centre = fieldTop + LauncherGeometry.fieldHeight * s / 2
    searchIcon.frame = NSRect(x: 28, y: centre - 12 * s, width: 24 * s, height: 24 * s)
    escHint.frame = NSRect(
      x: width - 28 - escHint.frame.width, y: centre - escHint.frame.height / 2,
      width: escHint.frame.width, height: escHint.frame.height)
    let fieldX = 28 + 24 * s + 16
    field.frame = NSRect(
      x: fieldX, y: fieldTop + 30 * s, width: max(0, escHint.frame.minX - 16 - fieldX),
      height: 30 * s)

    let listTop = fieldTop + LauncherGeometry.fieldHeight * s
    list.frame = NSRect(x: LauncherGeometry.padding, y: listTop, width: inner, height: shown)
    layoutList(sections, width: inner, shown: shown, full: full)

    let footerY = listTop + shown + LauncherGeometry.footerHeight * s / 2
    layoutFooter(width: width, centerY: footerY)
    layoutSubtreeIfNeeded()
  }

  /// Chrome text follows the text scale: fonts, the field, the chips, and the rows, which are
  /// rebuilt because their wrapping depends on it.
  func applyTextScale() {
    field.font = Fonts.ui(18)
    for label in keyLabels + [origin] { label.font = Fonts.ui(12) }
    for chip in [escHint] + keyChips { chip.applyTextScale() }
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 20 * Fonts.scale, weight: .regular))
    for view in rowViews.values { view.removeFromSuperview() }
    for label in headers.values { label.removeFromSuperview() }
    rowViews = [:]
    headers = [:]
    setScope(scope)
    updateOrigin()
    if isOpen { layoutPanel() }
  }

  /// Creates, updates and removes the row views, and measures each row.
  private func syncRows(_ sections: [LauncherSection], width: Double) {
    let liveIds = Set(rows.map(\.id))
    for (id, view) in rowViews where !liveIds.contains(id) {
      if window?.firstResponder === view { focusField() }
      view.removeFromSuperview()
      rowViews[id] = nil
    }
    let titles = Set(sections.map(\.title))
    for (title, label) in headers where !titles.contains(title) {
      label.removeFromSuperview()
      headers[title] = nil
    }
    rowHeights = [:]
    for row in rows {
      let view = rowViews[row.id] ?? makeRowView(row)
      view.update(row: row, active: row.id == activeId, animated: settled)
      rowHeights[row.id] = view.fittingHeight(width: width)
    }
  }

  private func layoutList(_ sections: [LauncherSection], width: Double, shown: Double, full: Double)
  {
    var y = 0.0
    var activeFrame: CGRect?
    for section in sections {
      let header = headers[section.title] ?? makeHeader(section.title)
      let band = LauncherGeometry.sectionHeight * Double(Fonts.scale)
      let text = 18 * Double(Fonts.scale)
      header.frame = NSRect(x: 12, y: y + (band - text) / 2, width: width - 24, height: text)
      y += band
      for row in section.rows {
        guard let view = rowViews[row.id], let height = rowHeights[row.id] else { continue }
        view.frame = NSRect(x: 0, y: y, width: width, height: height)
        if row.id == activeId { activeFrame = view.frame }
        y += height
      }
    }
    scrollOffset = scrolled(to: activeFrame, shown: shown, full: full)
    list.bounds.origin.y = scrollOffset
    moveFocusToActiveRow()
  }

  /// The list slides only as far as it must to keep the active row, and its header, in view.
  private func scrolled(to active: CGRect?, shown: Double, full: Double) -> Double {
    var offset = scrollOffset
    if let active {
      let top = active.minY - LauncherGeometry.sectionHeight * Double(Fonts.scale)
      if top < offset {
        offset = max(0, top)
      } else if active.maxY > offset + shown {
        offset = active.maxY - shown
      }
    }
    return max(0, min(offset, max(0, full - shown)))
  }

  private func layoutFooter(width: Double, centerY: Double) {
    let right = width - LauncherGeometry.padding - 12
    func place(_ view: NSView, right edge: Double) -> Double {
      (view as? NSTextField)?.sizeToFit()
      let size = view.frame.size
      view.frame = NSRect(
        x: edge - size.width, y: centerY - size.height / 2, width: size.width, height: size.height)
      return view.frame.minX - 8
    }
    var edge = right
    edge = place(keyLabels[1], right: edge)
    edge = place(keyChips[2], right: edge)
    edge = place(keyLabels[0], right: edge)
    edge = place(keyChips[1], right: edge)
    edge = place(keyChips[0], right: edge)
    origin.sizeToFit()
    let left = LauncherGeometry.padding + 12
    origin.frame = NSRect(
      x: left, y: centerY - origin.frame.height / 2,
      width: min(origin.frame.width, max(0, edge - 8 - left)), height: origin.frame.height)
  }

  private func makeHeader(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = Fonts.ui(12)
    label.textColor = Design.muted
    label.setAccessibilityRole(.staticText)
    list.addSubview(label)
    headers[title] = label
    return label
  }

  private func makeRowView(_ row: LauncherRow) -> LauncherRowView {
    let view = LauncherRowView(row: row)
    let id = row.id
    view.onChoose = { [weak self] in self?.onChoose?(id) }
    view.onFocus = { [weak self] in self?.onFocusRow?(id) }
    view.onTab = { [weak self] forward in self?.cycleFocus(forward: forward) }
    view.onMove = { [weak self] step in self?.onMove?(step) }
    view.onEscape = { [weak self] in self?.onDismiss?() }
    list.addSubview(view)
    rowViews[id] = view
    return view
  }

  /// Arrow keys change the active row; a focused row's ring follows it, and a row that went
  /// away hands focus back to the field.
  private func moveFocusToActiveRow() {
    guard let current = window?.firstResponder as? LauncherRowView else { return }
    if let id = activeId, let next = rowViews[id] {
      if next !== current { window?.makeFirstResponder(next) }
    } else {
      focusField()
    }
  }

  // MARK: Keyboard and mouse

  /// Tab walks the field and the enabled rows, and wraps: focus never leaves the launcher.
  func cycleFocus(forward: Bool) {
    var stops: [NSResponder] = [field]
    stops += rows.compactMap { rowViews[$0.id] }.filter { $0.row.enabled }
    let responder = window?.firstResponder
    let index = stops.firstIndex { $0 === responder } ?? 0
    let next = stops[(index + (forward ? 1 : stops.count - 1)) % stops.count]
    if next === field { focusField() } else { window?.makeFirstResponder(next) }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    isOpen ? super.hitTest(point) : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if panel.frame.contains(convert(event.locationInWindow, from: nil)) {
      focusField()
    } else {
      onDismiss?()
    }
  }

  override func scrollWheel(with event: NSEvent) {
    let full = contentHeight
    let shown = list.frame.height
    guard full > shown else { return }
    scrollOffset = max(0, min(scrollOffset - event.scrollingDeltaY, full - shown))
    list.bounds.origin.y = scrollOffset
  }

  func controlTextDidChange(_ notification: Notification) {
    let editor = notification.userInfo?["NSFieldEditor"] as? NSText
    onQuery?(editor?.string ?? field.stringValue)
  }

  /// Return and Escape belong to the input method while it holds marked text: the first
  /// confirms or cancels the composition and nothing more.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      if textView.hasMarkedText() {
        textView.unmarkText()
      } else {
        onChoose?(nil)
      }
    case #selector(NSResponder.cancelOperation(_:)):
      if textView.hasMarkedText() {
        textView.replaceCharacters(in: textView.markedRange(), with: "")
        textView.unmarkText()
        onQuery?(textView.string)
      } else {
        onDismiss?()
      }
    case #selector(NSResponder.moveDown(_:)): onMove?(1)
    case #selector(NSResponder.moveUp(_:)): onMove?(-1)
    case #selector(NSResponder.insertTab(_:)): cycleFocus(forward: true)
    case #selector(NSResponder.insertBacktab(_:)): cycleFocus(forward: false)
    default: return false
    }
    return true
  }
}

/// Glyph ink can reach past the line fragment the text system invalidates when text is replaced,
/// leaving the tops of old ascenders in the layer until something else repaints it. Every edit
/// repaints the whole editor, which is one line high.
final class LauncherEditor: NSTextView {
  override func didChangeText() {
    super.didChangeText()
    setNeedsDisplay(bounds)
  }
}
