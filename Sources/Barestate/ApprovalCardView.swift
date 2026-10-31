import AppKit
import BarestateCore

/// "Allow once" or "Deny", as text on a bordered button.
@MainActor
final class ApprovalButton: ChromeButton {
  private let caption: String
  private let tone: NSColor

  init(title: String, tone: NSColor) {
    caption = title
    self.tone = tone
    super.init(
      symbol: "", label: title, side: 32, corner: Design.radiusControl, tint: Design.ink)
    image = nil
    imagePosition = .noImage
    restFill = Design.surface
    layer?.borderWidth = 1
    layer?.borderColor = Design.lineStrong.cgColor
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private var attributed: NSAttributedString {
    NSAttributedString(
      string: caption,
      attributes: [.font: Fonts.ui(13, weight: 500), .foregroundColor: tone])
  }

  var labelFont: NSFont? { Fonts.ui(13, weight: 500) }
  var textWidth: CGFloat { ceil(attributed.size().width) }

  func applyTextScale() {
    attributedTitle = attributed
    setFrameSize(NSSize(width: textWidth + 28, height: 32 * Fonts.scale))
  }

  /// The petrol ring replaces the rest border while the keyboard is on the button.
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    layer?.borderWidth = 1
    layer?.borderColor = Design.lineStrong.cgColor
    return resigned
  }

  /// The title is drawn by the cell; any click inside is a click on the button.
  override func hitTest(_ point: NSPoint) -> NSView? {
    isHiddenOrHasHiddenAncestor || !frame.contains(point) ? nil : self
  }
}

/// The approval for one pending item, shown beside the page it is about (architecture §5.6):
/// the action in quotes, then Allow once and Deny. Its frame is set by the window, never by the
/// page, so the live page is not resized for it.
@MainActor
final class ApprovalCardView: NSView {
  let allow = ApprovalButton(title: "Allow once", tone: Design.petrol)
  let deny = ApprovalButton(title: "Deny", tone: Design.ink)
  private let quote = NSTextField(wrappingLabelWithString: "")
  private(set) var item: Approvals.Item?
  /// Set once a button was pressed: the card is on its way out and cannot be pressed again.
  private(set) var decided = false
  private var leaving = false
  var onDecide: ((Approvals.Item, Bool) -> Void)?

  private static let pad: CGFloat = 12
  private static let gap: CGFloat = 8

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Design.surface.cgColor
    layer?.borderColor = Design.line.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = Design.radiusPanel
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.08
    layer?.shadowRadius = 16
    layer?.shadowOffset = CGSize(width: 0, height: -8)
    isHidden = true
    quote.textColor = Design.ink
    quote.isSelectable = false
    quote.maximumNumberOfLines = 0
    quote.lineBreakMode = .byWordWrapping
    quote.setAccessibilityRole(.staticText)
    for button in [allow, deny] {
      button.target = self
      button.action = #selector(pressed(_:))
    }
    for view in [quote, allow, deny] as [NSView] { addSubview(view) }
    setAccessibilityRole(.group)
    setAccessibilityLabel("Approval")
    applyTextScale()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  var keyViews: [NSView] { [allow, deny] }
  var quoteFont: NSFont? { quote.font }
  var quoteText: String { quote.stringValue }

  @objc private func pressed(_ sender: ApprovalButton) {
    guard let item, !decided else { return }
    decided = true
    allow.isEnabled = false
    deny.isEnabled = false
    onDecide?(item, sender === allow)
  }

  func show(_ next: Approvals.Item) {
    item = next
    decided = false
    leaving = false
    allow.isEnabled = true
    deny.isEnabled = true
    quote.stringValue = next.text
    setAccessibilityLabel("Approval: \(next.text)")
    applyTextScale()
  }

  func applyTextScale() {
    quote.font = Fonts.ui(13, weight: 500)
    allow.applyTextScale()
    deny.applyTextScale()
  }

  /// Lays the card out in `width` and returns its height. The text wraps to as many lines as it
  /// needs; the buttons sit beside it when there is room and under it when there is not.
  @discardableResult
  func fit(width: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
    let pad = Self.pad
    let gap = Self.gap
    let buttons = allow.frame.width + deny.frame.width + gap
    let buttonHeight = allow.frame.height
    func measure(_ available: CGFloat) -> CGSize {
      let box = (quote.stringValue as NSString).boundingRect(
        with: NSSize(width: max(available, 1), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: quote.font as Any])
      return CGSize(width: ceil(box.width) + 2, height: ceil(box.height))
    }
    let beside = width - 2 * pad - buttons - gap
    let single = measure(.greatestFiniteMagnitude)
    let sideBySide = beside >= min(single.width, 180 * Fonts.scale)
    let height: CGFloat
    // A quote longer than the room shows its first lines and ends in an ellipsis; the buttons stay
    // in view, the tooltip and the socket's list hold the whole text.
    let line = ceil(quote.font.map { $0.ascender - $0.descender + $0.leading } ?? 16)
    func bounded(_ text: CGSize, room: CGFloat) -> CGSize {
      let lines = max(1, Int(floor(room / line)))
      let clipped = text.height > room && lines * Int(line) < Int(text.height)
      quote.maximumNumberOfLines = clipped ? lines : 0
      quote.lineBreakMode = clipped ? .byTruncatingTail : .byWordWrapping
      quote.toolTip = clipped ? quote.stringValue : nil
      return clipped ? CGSize(width: text.width, height: CGFloat(lines) * line) : text
    }
    if sideBySide {
      let text = bounded(measure(beside), room: maxHeight - 2 * pad)
      height = max(text.height, buttonHeight) + 2 * pad
      quote.frame = NSRect(
        x: pad, y: (height - text.height) / 2, width: beside, height: text.height)
      let y = (height - buttonHeight) / 2
      allow.frame.origin = NSPoint(x: width - pad - buttons, y: y)
      deny.frame.origin = NSPoint(x: width - pad - deny.frame.width, y: y)
    } else {
      let text = bounded(measure(width - 2 * pad), room: maxHeight - 2 * pad - gap - buttonHeight)
      quote.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: text.height)
      let y = pad + text.height + gap
      deny.frame.origin = NSPoint(x: width - pad - deny.frame.width, y: y)
      allow.frame.origin = NSPoint(x: deny.frame.minX - gap - allow.frame.width, y: y)
      height = y + buttonHeight + pad
    }
    setFrameSize(NSSize(width: width, height: height))
    return height
  }

  /// Every label shows whole: its frame holds the text it was given.
  var labelsFit: Bool {
    let needed = (quote.stringValue as NSString).boundingRect(
      with: NSSize(width: quote.frame.width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: quote.font as Any])
    return quote.maximumNumberOfLines == 0 && quote.frame.height >= ceil(needed.height)
      && allow.frame.width >= allow.textWidth && deny.frame.width >= deny.textWidth
      && bounds.contains(allow.frame) && bounds.contains(deny.frame)
  }

  // MARK: Entrance and exit (research/animation-plan.md, row 9)

  /// Scales about the top centre, where the card attaches to the page, and starts `travel` below.
  private func transform(scale: CGFloat, travel: CGFloat) -> CATransform3D {
    guard let layer else { return CATransform3DIdentity }
    let pivot = CGPoint(x: bounds.midX, y: layer.isGeometryFlipped ? 0 : bounds.height)
    var move = CATransform3DMakeScale(scale, scale, 1)
    move.m41 = pivot.x * (1 - scale)
    move.m42 = pivot.y * (1 - scale) + (layer.isGeometryFlipped ? travel : -travel)
    return move
  }

  func appear(animated: Bool) {
    isHidden = false
    layer?.removeAllAnimations()
    layer?.opacity = 1
    layer?.transform = CATransform3DIdentity
    guard animated, let layer else { return }
    let reduced = MotionLedger.shared.reduced()
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "approval.fade",
        animation: Motion.ease(
          "opacity", from: 0, to: 1, duration: reduced ? Motion.reducedFade : Motion.approvalIn))
    ]
    if !reduced {
      parts.append(
        .init(
          layer: layer, key: "approval.rise",
          animation: Motion.ease(
            "transform",
            from: NSValue(
              caTransform3D: transform(
                scale: Motion.approvalEnterScale, travel: Motion.approvalTravel)
            ), to: NSValue(caTransform3D: CATransform3DIdentity), duration: Motion.approvalIn)))
    }
    MotionLedger.shared.start(.approvalIn, target: item?.id ?? "", parts)
  }

  /// `quickly`: a takeover or the end of a run leaves with opacity alone, in 100 ms.
  func disappear(animated: Bool, quickly: Bool = false) {
    if leaving && !animated { return }
    decided = true
    allow.isEnabled = false
    deny.isEnabled = false
    guard animated, let layer, !isHidden else {
      isHidden = true
      leaving = false
      return
    }
    leaving = true
    let reduced = MotionLedger.shared.reduced()
    let fade = reduced ? Motion.reducedFade : quickly ? Motion.approvalQuickOut : Motion.approvalOut
    layer.opacity = 0
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "approval.fade",
        animation: Motion.ease("opacity", from: 1, to: 0, duration: fade))
    ]
    if !reduced && !quickly {
      layer.transform = transform(scale: Motion.approvalExitScale, travel: 0)
      parts.append(
        .init(
          layer: layer, key: "approval.rise",
          animation: Motion.ease(
            "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
            to: NSValue(caTransform3D: layer.transform), duration: fade)))
    }
    MotionLedger.shared.start(.approvalOut, target: item?.id ?? "", parts) { [weak self] _ in
      guard let self, self.leaving else { return }
      self.leaving = false
      self.isHidden = true
      self.layer?.opacity = 1
      self.layer?.transform = CATransform3DIdentity
    }
  }

  /// Nothing below the card's frame answers while it is leaving.
  override func hitTest(_ point: NSPoint) -> NSView? {
    isHiddenOrHasHiddenAncestor || !frame.contains(point) ? nil : super.hitTest(point)
  }
}
