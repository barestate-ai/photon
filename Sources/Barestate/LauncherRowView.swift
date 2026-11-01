import AppKit
import BarestateCore

/// A small bordered key cap: "Esc", "Enter" and the arrows in the launcher.
@MainActor
final class KeyChip: NSView {
  let label: NSTextField
  private let base: CGFloat

  init(_ text: String, width: CGFloat) {
    label = NSTextField(labelWithString: text)
    base = width
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    wantsLayer = true
    layer?.backgroundColor = Design.canvas.cgColor
    layer?.borderColor = Design.line.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = Design.radiusControl
    label.textColor = Design.muted
    label.alignment = .center
    addSubview(label)
    setAccessibilityElement(false)
    applyTextScale()
  }

  /// The chip's size is its design size times the text scale.
  func applyTextScale() {
    label.font = Fonts.hint()
    setFrameSize(NSSize(width: base * Fonts.scale, height: 24 * Fonts.scale))
    needsLayout = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let height = 17 * Fonts.scale
    label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
  }
}

/// One suggestion: icon, title, subtitle, and the Enter chip while it is the active row.
@MainActor
final class LauncherRowView: NSView {
  private(set) var row: LauncherRow
  var onChoose: (() -> Void)?
  /// The row got keyboard focus, which makes it the active row.
  var onFocus: (() -> Void)?
  var onTab: ((Bool) -> Void)?
  var onMove: ((Int) -> Void)?
  var onEscape: (() -> Void)?
  private(set) var isActive = false
  private var hovering = false
  private let icon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let hint = KeyChip("Enter", width: 48)

  override var isFlipped: Bool { true }

  init(row: LauncherRow) {
    self.row = row
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = Design.radiusControl
    applyTextScale()
    for part in [icon, titleLabel, subtitleLabel] as [NSView] { part.wantsLayer = true }
    for view in [icon, titleLabel, subtitleLabel, hint] as [NSView] { addSubview(view) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    for part in [icon, titleLabel, subtitleLabel, hint] as [NSView] {
      part.setAccessibilityElement(false)
    }
    update(row: row, active: false, animated: false)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var rowId: String { row.id }
  var showsHint: Bool { !hint.isHidden }
  var hasFocus: Bool { window?.firstResponder === self }

  /// The design's row states, as `test.ui` reports them.
  var state: String {
    if !row.enabled { return "disabled" }
    if row.status != .ready { return row.status.rawValue }
    if hasFocus { return "focus" }
    return isActive ? "selected" : "default"
  }

  /// A run row whose state changed in place: the new icon and subtitle fade in. Selection, focus
  /// and rows that are unavailable stay instant.
  private func crossfadeState(to next: LauncherRow) {
    let changed = row.status != next.status || row.kind == .run && row.subtitle != next.subtitle
    guard window != nil, row.id == next.id, changed, row.enabled, next.enabled else { return }
    let reduced = MotionLedger.shared.reduced()
    let duration = reduced ? Motion.reducedFade : Motion.fadeSmall
    var parts: [MotionLedger.Part] = [icon, titleLabel, subtitleLabel].compactMap { $0.layer }.map {
      .init(
        layer: $0, key: "rowState",
        animation: Motion.ease("opacity", from: 0, to: 1, duration: duration))
    }
    if next.status == .success, !reduced, let layer = icon.layer {
      let scale = Motion.readyIconScale
      var from = CATransform3DMakeScale(scale, scale, 1)
      from.m41 = icon.bounds.midX * (1 - scale)
      from.m42 = icon.bounds.midY * (1 - scale)
      parts.append(
        .init(
          layer: layer, key: "rowState.scale",
          animation: Motion.ease(
            "transform", from: NSValue(caTransform3D: from),
            to: NSValue(caTransform3D: CATransform3DIdentity), duration: duration)))
    }
    MotionLedger.shared.start(.rowState, target: next.id, parts)
  }

  func update(row: LauncherRow, active: Bool, animated: Bool) {
    if animated { crossfadeState(to: row) }
    self.row = row
    isActive = active && row.enabled
    titleLabel.stringValue = row.title
    subtitleLabel.stringValue = row.subtitle
    hint.isHidden = !isActive
    titleLabel.textColor =
      row.kind == .retry ? Design.petrol : row.enabled ? Design.ink : Design.muted
    subtitleLabel.textColor = isActive ? Design.mutedOnSelection : Design.muted
    icon.image = Self.image(for: row)
    icon.contentTintColor = row.kind == .retry ? Design.petrol : Design.ink
    paintFill()
    setAccessibilityLabel("\(row.title), \(row.subtitle)")
    setAccessibilityEnabled(row.enabled)
    setAccessibilityHelp(row.enabled ? nil : row.subtitle)
    needsLayout = true
  }

  /// Above 1 the text wraps instead of truncating and the row grows to hold it.
  func applyTextScale() {
    let wrap = Fonts.scale > 1
    titleLabel.font = Fonts.ui(16, weight: 500)
    subtitleLabel.font = Fonts.ui(13)
    for label in [titleLabel, subtitleLabel] {
      label.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
      label.maximumNumberOfLines = wrap ? 0 : 1
      label.cell?.wraps = wrap
    }
    hint.applyTextScale()
    needsLayout = true
  }

  private static let textX: CGFloat = 12 + 24 + 16

  /// The hint's room is kept even when the row is not active, so selecting never reflows text.
  private func textWidth(in width: CGFloat) -> CGFloat {
    max(0, width - Self.textX - (isActive || Fonts.scale > 1 ? 12 + hint.frame.width + 16 : 12))
  }

  private func textHeights(in width: CGFloat) -> (title: CGFloat, subtitle: CGFloat) {
    guard Fonts.scale > 1 else { return (23, 19) }
    let box = NSRect(x: 0, y: 0, width: textWidth(in: width), height: .greatestFiniteMagnitude)
    func fit(_ label: NSTextField) -> CGFloat {
      ceil(label.cell?.cellSize(forBounds: box).height ?? 0)
    }
    return (fit(titleLabel), fit(subtitleLabel))
  }

  /// 64 pt at scale 1; larger, and as tall as the wrapped text needs, otherwise.
  func fittingHeight(width: CGFloat) -> CGFloat {
    let (title, subtitle) = textHeights(in: width)
    return max(LauncherGeometry.rowHeight * Fonts.scale, title + subtitle + 22)
  }

  private func paintFill() {
    let fill = isActive ? Design.selection : hovering && row.enabled ? Design.hover : nil
    layer?.backgroundColor = fill?.cgColor
  }

  /// The Lift task mark stands for work Muse does; a row that cannot run or is waiting keeps it.
  private static func image(for row: LauncherRow) -> NSImage? {
    if row.kind == .startTask || row.status == .loading {
      return Design.liftMark(height: 16.8)
    }
    let name: String
    switch row.kind {
    case .switchTab, .run: name = "doc"
    case .openURL, .history: name = "globe"
    case .bookmark: name = "star"
    case .search, .findWeb: name = "magnifyingglass"
    case .retry: name = "arrow.clockwise"
    case .startTask: name = "doc"
    case .command:
      name = BrowserCommand(rawValue: row.target).map(Self.symbol) ?? "command"
    }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
  }

  private static func symbol(_ command: BrowserCommand) -> String {
    switch command {
    case .back: "chevron.left"
    case .forward: "chevron.right"
    case .reload: "arrow.clockwise"
    case .history: "clock"
    case .openPages: "square.on.square"
    case .settings: "slider.horizontal.3"
    case .showOverview: "square.grid.2x2"
    case .focusPage: "rectangle"
    case .zoomIn: "plus.magnifyingglass"
    case .zoomOut: "minus.magnifyingglass"
    case .zoomToFit: "arrow.up.left.and.down.right.magnifyingglass"
    case .find: "text.magnifyingglass"
    case .closePage: "xmark"
    case .reopenClosed: "arrow.uturn.backward"
    case .stopRun: "stop.circle"
    case .showRunActivity: "list.bullet"
    case .disconnectPhone: "iphone.slash"
    }
  }

  override func layout() {
    super.layout()
    let height = bounds.height
    icon.frame = NSRect(x: 12, y: (height - 24) / 2, width: 24, height: 24)
    icon.imageScaling = .scaleNone
    let (titleHeight, subtitleHeight) = textHeights(in: bounds.width)
    let top = ((height - titleHeight - subtitleHeight) / 2).rounded()
    let textWidth = textWidth(in: bounds.width)
    titleLabel.frame = NSRect(x: Self.textX, y: top, width: textWidth, height: titleHeight)
    subtitleLabel.frame = NSRect(
      x: Self.textX, y: top + titleHeight, width: textWidth, height: subtitleHeight)
    hint.frame = NSRect(
      x: bounds.width - 12 - hint.frame.width, y: (height - hint.frame.height) / 2,
      width: hint.frame.width, height: hint.frame.height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    paintFill()
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    paintFill()
  }

  override func mouseDown(with event: NSEvent) {
    if row.enabled { onChoose?() }
  }

  /// A click chooses the row and never moves focus; only the keyboard does.
  override var acceptsFirstResponder: Bool {
    row.enabled && NSApp.currentEvent?.type != .leftMouseDown
  }

  override func becomeFirstResponder() -> Bool {
    layer?.borderWidth = 2
    layer?.borderColor = Design.petrol.cgColor
    onFocus?()
    return true
  }

  override func resignFirstResponder() -> Bool {
    layer?.borderWidth = 0
    return true
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76, 49: onChoose?()
    case 48: onTab?(!event.modifierFlags.contains(.shift))
    case 53: onEscape?()
    case 125: onMove?(1)
    case 126: onMove?(-1)
    default: break
    }
  }

  override func isAccessibilitySelected() -> Bool { isActive }

  override func accessibilityChildren() -> [Any]? { [] }

  override func accessibilityActionNames() -> [NSAccessibility.Action] {
    MainActor.assumeIsolated { row.enabled ? [.press] : [] }
  }

  override func accessibilityValue() -> Any? { row.enabled ? nil : "unavailable" }

  override func accessibilityPerformPress() -> Bool {
    guard row.enabled else { return false }
    onChoose?()
    return true
  }
}
