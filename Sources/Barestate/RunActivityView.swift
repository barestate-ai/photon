import AppKit
import BarestateCore

/// "Show Muse activity": a panel over the window listing what one task did, step by step, and
/// what it waits for a person to decide. The view fills the window so a click outside the panel
/// closes it and nothing behind takes the click; closing never stops the task.
@MainActor
final class RunActivityView: NSView {
  var onStop: (() -> Void)?
  var onClose: (() -> Void)?
  let panel = FlippedView()
  let stop = ApprovalButton(title: "Stop", tone: Design.ink)
  let close = ApprovalButton(title: "Close", tone: Design.ink)
  private let heading = NSTextField(labelWithString: "Muse activity")
  private let prompt = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(labelWithString: "")
  private let list = FlippedView()
  private var rows: [NSTextField] = []
  private var entryCount = 0
  private var activity: RunActivity?
  private var scrollOffset = 0.0
  private var contentHeight = 0.0

  private static let pad: CGFloat = 20
  private static let gap: CGFloat = 10
  private static let top: CGFloat = 96

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    panel.wantsLayer = true
    panel.layer?.backgroundColor = Design.surface.cgColor
    panel.layer?.cornerRadius = Design.radiusPanel
    panel.layer?.borderWidth = 1
    panel.layer?.borderColor = Design.line.cgColor
    panel.layer?.shadowColor = NSColor.black.cgColor
    panel.layer?.shadowOpacity = 0.08
    panel.layer?.shadowRadius = 16
    panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
    panel.setAccessibilityElement(true)
    panel.setAccessibilityEnabled(true)
    panel.setAccessibilityRole(.group)
    panel.setAccessibilityLabel("Muse activity")
    list.wantsLayer = true
    list.layer?.masksToBounds = true
    heading.textColor = Design.ink
    prompt.textColor = Design.ink
    prompt.maximumNumberOfLines = 2
    prompt.lineBreakMode = .byTruncatingTail
    status.textColor = Design.muted
    status.lineBreakMode = .byTruncatingTail
    for label in [heading, prompt, status] { label.setAccessibilityRole(.staticText) }
    stop.target = self
    stop.action = #selector(stopPressed)
    close.target = self
    close.action = #selector(closePressed)
    stop.nextKeyView = close
    close.nextKeyView = stop
    addSubview(panel)
    for view in [heading, prompt, status, list, stop, close] as [NSView] { panel.addSubview(view) }
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var isOpen: Bool { !isHidden }

  @objc private func stopPressed() { onStop?() }
  @objc private func closePressed() { onClose?() }

  func applyTextScale() {
    heading.font = Fonts.ui(15, weight: 500)
    prompt.font = Fonts.ui(13)
    status.font = Fonts.ui(12)
    stop.applyTextScale()
    close.applyTextScale()
    if let activity { render(activity) }
  }

  // MARK: Showing

  func show(_ next: RunActivity) {
    isHidden = false
    scrollOffset = 0
    render(next)
  }

  func hide() {
    isHidden = true
    activity = nil
  }

  func render(_ next: RunActivity) {
    activity = next
    prompt.stringValue = next.prompt
    let because = next.reason.flatMap { $0 == next.status ? nil : " · \($0)" } ?? ""
    status.stringValue = "Muse · \(next.status)\(because)"
    stop.isEnabled = next.canStop
    stop.setAccessibilityLabel(next.canStop ? "Stop \(next.prompt)" : "Stop")
    close.setAccessibilityLabel("Close Muse activity")
    rebuildList(next)
    layoutPanel()
    NSAccessibility.post(element: panel, notification: .layoutChanged)
  }

  private func line(_ title: String, _ detail: String, label: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    let text = NSMutableAttributedString(
      string: title, attributes: [.font: Fonts.ui(13), .foregroundColor: Design.ink])
    if !detail.isEmpty {
      text.append(
        NSAttributedString(
          string: "\n\(detail)",
          attributes: [.font: Fonts.ui(12), .foregroundColor: Design.muted]))
    }
    field.attributedStringValue = text
    field.setAccessibilityRole(.staticText)
    field.setAccessibilityLabel(label)
    return field
  }

  private func rebuildList(_ next: RunActivity) {
    for view in list.subviews { view.removeFromSuperview() }
    var fields = next.entries.map { line($0.text, $0.detail, label: "\($0.text), \($0.detail)") }
    entryCount = fields.count
    if fields.isEmpty { fields = [line("No steps yet", "", label: "No steps yet")] }
    fields += next.waiting.map {
      line(
        $0, "Waiting for you · decide with the approval card on its page",
        label: "Waiting for you: \($0)")
    }
    rows = fields
    for field in rows { list.addSubview(field) }
  }

  // MARK: Layout

  private func height(of field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(
      field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 0)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if isOpen { layoutPanel() }
  }

  private func layoutPanel() {
    let s = Fonts.scale
    let pad = Self.pad
    let width = min(520 * s, bounds.width - 32)
    let inner = width - 2 * pad
    var y = pad
    heading.frame = NSRect(
      x: pad, y: y, width: inner, height: ceil(heading.intrinsicContentSize.height))
    y = heading.frame.maxY + 6
    let promptHeight = min(
      height(of: prompt, width: inner),
      ceil(prompt.font.map { $0.boundingRectForFont.height * 2 } ?? 40))
    prompt.frame = NSRect(x: pad, y: y, width: inner, height: promptHeight)
    y = prompt.frame.maxY + 2
    status.frame = NSRect(
      x: pad, y: y, width: inner, height: ceil(status.intrinsicContentSize.height))
    y = status.frame.maxY + Self.gap

    var inside: CGFloat = 0
    for (index, field) in rows.enumerated() {
      let h = height(of: field, width: inner)
      field.frame = NSRect(x: 0, y: inside, width: inner, height: h)
      inside += h + Self.gap
      if index + 1 == max(entryCount, 1), index + 1 < rows.count { inside += Self.gap }
    }
    contentHeight = max(0, inside - Self.gap)
    let buttons = max(stop.frame.height, close.frame.height)
    let room = max(
      60 * s, bounds.height - Self.top - 96 * s - (y + Self.gap + buttons + pad))
    let shown = min(contentHeight, room)
    list.frame = NSRect(x: pad, y: y, width: inner, height: shown)
    scrollOffset = max(0, min(scrollOffset, contentHeight - shown))
    list.bounds.origin.y = scrollOffset
    y = list.frame.maxY + Self.gap
    close.frame.origin = NSPoint(x: width - pad - close.frame.width, y: y)
    stop.frame.origin = NSPoint(x: close.frame.minX - 8 - stop.frame.width, y: y)
    panel.frame = NSRect(
      x: ((bounds.width - width) / 2).rounded(), y: Self.top, width: width,
      height: y + buttons + pad)
  }

  // MARK: Entrance

  func appear() {
    guard let layer = panel.layer else { return }
    let reduced = MotionLedger.shared.reduced()
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "activity.fade",
        animation: Motion.ease(
          "opacity", from: 0, to: 1, duration: reduced ? Motion.reducedFade : Motion.approvalIn))
    ]
    if !reduced {
      parts.append(
        .init(
          layer: layer, key: "activity.rise",
          animation: Motion.ease(
            "transform",
            from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, Motion.approvalTravel, 0)),
            to: NSValue(caTransform3D: CATransform3DIdentity), duration: Motion.approvalIn)))
    }
    MotionLedger.shared.start(.activityIn, target: activity?.runId ?? "", parts)
  }

  // MARK: Keyboard and mouse

  override func hitTest(_ point: NSPoint) -> NSView? {
    isOpen ? super.hitTest(point) : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onClose?()
    } else {
      super.keyDown(with: event)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    let shown = list.frame.height
    guard contentHeight > shown else { return }
    scrollOffset = max(0, min(scrollOffset - event.scrollingDeltaY, contentHeight - shown))
    list.bounds.origin.y = scrollOffset
  }
}
