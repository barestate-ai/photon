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
  /// The model's closing reply; hidden when the run has none.
  private let answer = NSTextField(wrappingLabelWithString: "")
  private let list = FlippedView()
  /// Step lines, kept across renders of one run so their text updates in place.
  private var rows: [NSTextField] = []
  /// The placeholder and the waiting lines, rebuilt on each render.
  private var extras: [NSTextField] = []
  private var renderedRun: String?
  private var activity: RunActivity?
  private var scrollOffset = 0.0
  private var contentHeight = 0.0
  /// Closed in the model, still fading out on screen: `isHidden` waits for the fade.
  private var leaving = false

  private static let pad: CGFloat = 20
  private static let gap: CGFloat = 10
  private static let top: CGFloat = 96
  private static let answerLines = 8

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isHidden = true
    panel.wantsLayer = true
    panel.layer?.opacity = 0
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
    answer.textColor = Design.ink
    answer.maximumNumberOfLines = Self.answerLines
    answer.lineBreakMode = .byTruncatingTail
    answer.isHidden = true
    for label in [heading, prompt, status, answer] { label.setAccessibilityRole(.staticText) }
    stop.target = self
    stop.action = #selector(stopPressed)
    close.target = self
    close.action = #selector(closePressed)
    stop.nextKeyView = close
    close.nextKeyView = stop
    addSubview(panel)
    for view in [heading, prompt, status, answer, list, stop, close] as [NSView] {
      panel.addSubview(view)
    }
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var isOpen: Bool { !isHidden && !leaving }

  @objc private func stopPressed() { onStop?() }
  @objc private func closePressed() { onClose?() }

  func applyTextScale() {
    heading.font = Fonts.ui(15, weight: 500)
    prompt.font = Fonts.ui(13)
    status.font = Fonts.ui(12)
    answer.font = Fonts.ui(13)
    stop.applyTextScale()
    close.applyTextScale()
    if let activity { render(activity) }
  }

  // MARK: Showing

  func show(_ next: RunActivity) {
    leaving = false
    isHidden = false
    scrollOffset = 0
    render(next, animated: false)
  }

  /// The panel leaves with a fade; a closed panel always has opacity 0, which is where `appear`
  /// starts from, so a reopen during the fade resumes from the frame on screen.
  func hide() {
    let run = activity?.runId ?? ""
    activity = nil
    guard let layer = panel.layer, isOpen else { return }
    leaving = true
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 1
    layer.opacity = 0
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.approvalQuickOut
    MotionLedger.shared.start(
      .activityOut, target: run,
      [
        .init(
          layer: layer, key: "activity.fade",
          animation: Motion.ease("opacity", from: from, to: 0, duration: duration))
      ]
    ) { [weak self] _ in
      guard let self, leaving else { return }
      leaving = false
      isHidden = true
    }
  }

  /// `animated`: lines added since the last render fade in; the first draw of a panel does not.
  func render(_ next: RunActivity, animated: Bool = true) {
    activity = next
    prompt.stringValue = next.prompt
    let because = next.because.flatMap { $0 == next.status ? nil : " · \($0)" } ?? ""
    status.stringValue = "Muse · \(next.status)\(because)"
    answer.stringValue = next.answer ?? ""
    answer.isHidden = next.answer == nil
    answer.setAccessibilityLabel(next.answer.map { "Muse's reply: \($0)" })
    stop.isEnabled = next.canStop
    stop.setAccessibilityLabel(next.canStop ? "Stop \(next.prompt)" : "Stop")
    close.setAccessibilityLabel("Close Muse activity")
    rebuildList(next, animated: animated)
    layoutPanel()
    NSAccessibility.post(element: panel, notification: .layoutChanged)
  }

  private func fill(_ field: NSTextField, _ title: String, _ detail: String, label: String) {
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
  }

  private func line(_ title: String, _ detail: String, label: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    fill(field, title, detail, label: label)
    return field
  }

  /// Entry rows are kept and their text updated in place, so a line the person reads never gets
  /// swapped out and a fade lands on the row that stays. A run's steps only grow; a different
  /// run starts the list over without fading.
  private func rebuildList(_ next: RunActivity, animated: Bool) {
    let sameRun = renderedRun == next.runId
    if !sameRun {
      for row in rows { row.removeFromSuperview() }
      rows = []
      renderedRun = next.runId
    }
    for extra in extras { extra.removeFromSuperview() }
    var fresh: [NSTextField] = []
    for (index, entry) in next.entries.enumerated() {
      if index < rows.count {
        fill(rows[index], entry.text, entry.detail, label: "\(entry.text), \(entry.detail)")
      } else {
        let field = line(entry.text, entry.detail, label: "\(entry.text), \(entry.detail)")
        rows.append(field)
        list.addSubview(field)
        if sameRun, animated { fresh.append(field) }
      }
    }
    while rows.count > next.entries.count { rows.removeLast().removeFromSuperview() }
    extras = []
    if next.entries.isEmpty { extras.append(line("No steps yet", "", label: "No steps yet")) }
    extras += next.waiting.map {
      line(
        $0, "Waiting for you · decide with the approval card on its page",
        label: "Waiting for you: \($0)")
    }
    for extra in extras { list.addSubview(extra) }
    if !fresh.isEmpty { fadeIn(fresh, run: next.runId) }
  }

  /// Opacity only: the lines keep their frames, so nothing the person is reading moves.
  private func fadeIn(_ fields: [NSTextField], run: String) {
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.fadeSmall
    let parts = fields.compactMap { field -> MotionLedger.Part? in
      field.wantsLayer = true
      guard let layer = field.layer else { return nil }
      return .init(
        layer: layer, key: "step.fade",
        animation: Motion.ease("opacity", from: 0, to: 1, duration: duration))
    }
    MotionLedger.shared.start(.stepIn, target: run, parts)
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
    if !answer.isHidden {
      let line = answer.font?.boundingRectForFont.height ?? 0
      let most = ceil(line * CGFloat(Self.answerLines))
      answer.frame = NSRect(
        x: pad, y: y, width: inner, height: min(height(of: answer, width: inner), most))
      y = answer.frame.maxY + Self.gap
    }

    var inside: CGFloat = 0
    let all = rows + extras
    for (index, field) in all.enumerated() {
      let h = height(of: field, width: inner)
      field.frame = NSRect(x: 0, y: inside, width: inner, height: h)
      inside += h + Self.gap
      if index + 1 == max(rows.count, 1), index + 1 < all.count { inside += Self.gap }
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
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 0
    layer.opacity = 1
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "activity.fade",
        animation: Motion.ease(
          "opacity", from: from, to: 1,
          duration: reduced ? Motion.reducedFade : Motion.approvalIn))
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
