import AppKit
import BarestateCore
import CEFBridge

/// Holds every tab's content view; only the active one is visible.
final class ContentContainerView: NSView {
  override var isFlipped: Bool { true }

  func show(_ active: NSView?) {
    for view in subviews { view.isHidden = view !== active }
  }
}

/// The window's content: the canvas, the tab views over it, the command button, the page
/// caption, the find bar and the launcher. Nothing else draws in the window; the traffic lights
/// sit over the canvas.
@MainActor
final class WindowRootView: NSView {
  let container = ContentContainerView()
  let commandButton = CommandButton()
  let caption = PageCaptionView()
  let findBar = FindBarView()
  let flightView = FlightView()
  let launcher = LauncherView()
  let approvalCard = ApprovalCardView()
  let activity = RunActivityView()
  let phoneChip = PhoneChipView()
  private(set) var canvasView: CanvasView?
  weak var camera: CameraTransition?
  private(set) var focusContext: FocusContextView!
  /// The pages beside the focused one, before the layout decides how many fit.
  private(set) var context: (left: [PageNode], right: [PageNode]) = ([], [])
  private(set) var focusLayout = FocusLayout.make(size: .zero, left: 0, right: 0)
  private let notice = NSTextField(labelWithString: "")
  private var noticeTimer: Task<Void, Never>?
  private let mark = NSImageView()
  private let wordmark = NSTextField(labelWithString: "Photon")
  private let compactChip = FlippedView()
  private let compactKey = NSTextField(labelWithString: "⌘T")

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Design.canvas.cgColor
    mark.image = Design.liftMark(height: 16.8)
    wordmark.textColor = Design.ink
    caption.wantsLayer = true
    compactChip.wantsLayer = true
    compactChip.layer?.backgroundColor = Design.surface.cgColor
    compactChip.layer?.borderColor = Design.line.cgColor
    compactChip.layer?.borderWidth = 1
    compactChip.layer?.cornerRadius = Design.radiusPanel
    compactChip.isHidden = true
    notice.textColor = Design.ink
    notice.alignment = .center
    notice.isHidden = true
    notice.setAccessibilityElement(false)
    compactKey.textColor = Design.muted
    compactChip.addSubview(compactKey)
    applyTextScale()
    for view in [mark, wordmark] {
      view.setAccessibilityElement(false)
      view.wantsLayer = true
    }
    for view in [
      mark, wordmark, container, caption, notice, commandButton, compactChip, findBar,
      approvalCard, phoneChip, activity, launcher,
    ]
      as [NSView]
    {
      addSubview(view)
    }
    linkKeyLoop()
    layoutChildren()
  }

  /// Tab walks the approval's buttons, the canvas, the overview's title, the command button and
  /// the find controls; the views that are hidden in the current presentation are skipped.
  private func linkKeyLoop() {
    let title = canvasView.map { [$0.titleField] } ?? []
    let loop: [NSView] =
      [self] + approvalCard.keyViews + title + [commandButton, phoneChip.disconnect]
      + findBar.keyViews.map(\.view)
      + [self]
    for (from, to) in zip(loop, loop.dropFirst()) { from.nextKeyView = to }
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutChildren()
  }

  /// Chrome text and the controls around it follow `Fonts.scale`.
  func applyTextScale() {
    wordmark.font = Fonts.ui(18, weight: 500)
    notice.font = Fonts.ui(13)
    compactKey.font = Fonts.hint(14)
    compactKey.sizeToFit()
    commandButton.applyTextScale()
    approvalCard.applyTextScale()
    phoneChip.applyTextScale()
    activity.applyTextScale()
    caption.applyTextScale()
    findBar.applyTextScale()
    canvasView?.legend.show(canvasView?.legend.items ?? [], force: true)
    launcher.applyTextScale()
    layoutChildren()
  }

  /// Where the focused page sits: the card of its layout, whatever the presentation, so showing
  /// or hiding a page never resizes it.
  var pageRect: NSRect { focusLayout.card }

  func setContext(_ next: (left: [PageNode], right: [PageNode])) {
    guard next.left != context.left || next.right != context.right else { return }
    context = next
    layoutChildren()
  }

  /// A click on the bare canvas takes focus off the page, which is how the keyboard reaches the
  /// command button: Tab from here.
  override var acceptsFirstResponder: Bool { true }

  /// Tab or Shift-Tab reached this view: the loop has come round to the page.
  var onKeyLoopReturn: (() -> Void)?

  override func becomeFirstResponder() -> Bool {
    if window?.keyViewSelectionDirection != .directSelection {
      // Chromium moves the responder itself; doing it inside this call would be overwritten.
      Task { onKeyLoopReturn?() }
    }
    return super.becomeFirstResponder()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      moveKeyFocus(event)
    } else if canvasView?.handleKey(event) != true {
      super.keyDown(with: event)
    }
  }

  /// The overview covers the pages and sits under the rest of the chrome; the focused page's
  /// context stands between the two.
  func install(_ canvas: CanvasView, focus: FocusContextView) {
    canvasView = canvas
    focusContext = focus
    canvas.layer?.backgroundColor = Design.canvas.cgColor
    addSubview(canvas, positioned: .above, relativeTo: container)
    addSubview(focus, positioned: .above, relativeTo: canvas)
    addSubview(flightView, positioned: .above, relativeTo: focus)
    for view in [mark, wordmark] as [NSView] {
      addSubview(view, positioned: .above, relativeTo: canvas)
    }
    linkKeyLoop()
    layoutChildren()
  }

  /// The empty overview's elements arrive one after another: the mark and wordmark, the canvas
  /// title, then the command button. Plays once, when the app starts with no pages.
  func playFirstRun() {
    let reduced = MotionLedger.shared.reduced()
    let groups:
      [(views: [NSView?], delay: CFTimeInterval, travel: CGFloat, duration: CFTimeInterval)] = [
        ([mark, wordmark], 0, Motion.firstRunTravel, Motion.firstRunText),
        (
          [canvasView?.titleField], Motion.firstRunStagger, Motion.firstRunTravel,
          Motion.firstRunText
        ),
        ([commandButton], 2 * Motion.firstRunStagger, 8, Motion.firstRunButton),
      ]
    var parts: [MotionLedger.Part] = []
    for group in groups {
      for case let layer? in group.views.map({ $0?.layer }) {
        let delay = reduced ? 0 : group.delay
        parts.append(
          .init(
            layer: layer, key: "firstRun.fade",
            animation: Motion.ease(
              "opacity", from: 0, to: 1, duration: reduced ? Motion.reducedFade : group.duration,
              delay: delay)))
        guard !reduced else { continue }
        parts.append(
          .init(
            layer: layer, key: "firstRun.rise",
            animation: Motion.ease(
              "transform",
              from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, group.travel, 0)),
              to: NSValue(caTransform3D: CATransform3DIdentity), duration: group.duration,
              delay: delay)))
      }
    }
    MotionLedger.shared.start(.firstRun, target: "overview", parts)
  }

  /// A short message in the identity row, clear of the page.
  func showNotice(_ text: String?) {
    noticeTimer?.cancel()
    notice.stringValue = text ?? ""
    notice.isHidden = text == nil
    notice.sizeToFit()
    layoutChildren()
    guard text != nil else { return }
    noticeTimer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      self?.showNotice(nil)
    }
  }

  var noticeText: String? { notice.isHidden ? nil : notice.stringValue }
  var noticeFrame: NSRect { notice.frame }

  private var compactButton = false
  /// The approval card needs the strip the command button sits in.
  private var approvalCovers = false

  func setCommandButtonCompact(_ compact: Bool) {
    compactButton = compact
    commandButton.isHidden = compact || approvalCovers
    compactChip.isHidden = !compact
  }

  // MARK: Approval

  /// Which page the card is about and where it attaches: the live page in the focused
  /// presentation, the page's node in the overview. nil hides the card.
  struct ApprovalAnchor {
    var item: Approvals.Item
    var focused: Bool
    var nodeId: String?
  }

  private(set) var approvalAnchor: ApprovalAnchor?

  /// A decided or withdrawn card leaves; `quickly` is a takeover or the end of a run.
  func setApproval(_ next: ApprovalAnchor?, animated: Bool = true, quickly: Bool = false) {
    let before = approvalAnchor
    approvalAnchor = next
    guard let next else {
      if !approvalCard.isHidden { approvalCard.disappear(animated: animated, quickly: quickly) }
      uncoverBottom()
      return
    }
    let entering = approvalCard.isHidden || approvalCard.decided || before?.item.id != next.item.id
    if entering { approvalCard.show(next.item) }
    guard placeApproval() else {
      approvalCard.disappear(animated: false)
      return
    }
    if entering { approvalCard.appear(animated: animated) }
  }

  private func uncoverBottom() {
    caption.alphaValue = 1
    approvalCovers = false
    commandButton.isHidden = compactButton
  }

  /// Puts the card under its anchor, inside the window, clear of the live page. False when there
  /// is nowhere to attach it.
  @discardableResult
  private func placeApproval() -> Bool {
    guard let anchor = approvalAnchor else { return false }
    let scale = Fonts.scale
    let target: CGRect
    if anchor.focused {
      target = pageRect
    } else if let id = anchor.nodeId, let rect = canvasView?.cardRect(id) {
      target = rect
    } else {
      return false
    }
    let width = min(
      bounds.width - 16, anchor.focused ? target.width : max(target.width, 320 * scale))
    let room =
      anchor.focused
      ? bounds.height - 12 - target.maxY
      : max(
        80 * scale,
        (compactButton ? compactChip.frame.minY : commandButton.frame.minY) - 16
          - target.minY - PageGraph.nodeHeight * CGFloat(canvasView?.zoomLevel ?? 1))
    let height = approvalCard.fit(width: width, maxHeight: room)
    let x = min(
      max(8, anchor.focused ? target.minX : target.midX - width / 2), bounds.width - 8 - width)
    // On the canvas the card gives way to the command button; beside a live page it stays off the
    // page and the button hides while the card covers it (⌘T still opens the launcher).
    let floor = (compactButton ? compactChip.frame.minY : commandButton.frame.minY) - 8
    var y: CGFloat
    if anchor.focused {
      y = min(target.maxY + 4, bounds.height - 8 - height)
    } else {
      let zoom = CGFloat(canvasView?.zoomLevel ?? 1)
      y = target.minY + PageGraph.nodeHeight * zoom + 8
      if y + height > floor { y = max(8, target.minY - 34 - height) }
      y = min(y, floor - height)
    }
    approvalCard.frame.origin = NSPoint(x: x.rounded(), y: y.rounded())
    let frame = approvalCard.frame
    caption.alphaValue = anchor.focused && frame.intersects(caption.frame) ? 0 : 1
    approvalCovers =
      frame.maxY + 8 > commandButton.frame.minY && frame.minX < commandButton.frame.maxX
      && frame.maxX > commandButton.frame.minX
    commandButton.isHidden = compactButton || approvalCovers
    return true
  }

  var compactChipVisible: Bool { !compactChip.isHidden }

  func layoutChildren() {
    mark.frame = NSRect(x: 48, y: 45.6, width: 24, height: 16.8)
    wordmark.sizeToFit()
    wordmark.frame.origin = NSPoint(x: 80, y: 41)
    canvasView?.frame = bounds
    focusContext?.frame = bounds
    flightView.frame = bounds
    container.frame = bounds
    focusLayout = FocusLayout.make(
      size: bounds.size, left: context.left.count, right: context.right.count,
      scale: Fonts.scale)
    notice.frame = NSRect(
      x: ((bounds.width - notice.frame.width) / 2).rounded(), y: 44, width: notice.frame.width,
      height: notice.frame.height)
    let page = pageRect
    let stale = container.subviews.filter { $0.frame != page }
    let landing = stale.isEmpty ? false : camera?.settle() ?? false
    for view in stale {
      if MotionLedger.shared.running(.camera) { MotionLedger.shared.noteLiveViewResize() }
      view.frame = page
    }
    caption.frame = focusLayout.caption
    commandButton.frame.origin = NSPoint(
      x: ((bounds.width - CommandButton.width) / 2).rounded(),
      y: bounds.height - 16 - CommandButton.height)
    let chip = NSSize(width: 64 * Fonts.scale, height: 40 * Fonts.scale)
    compactChip.frame = NSRect(
      x: ((bounds.width - chip.width) / 2).rounded(), y: bounds.height - 20 - chip.height,
      width: chip.width, height: chip.height)
    compactKey.frame.origin = NSPoint(
      x: (chip.width - compactKey.frame.width) / 2, y: (chip.height - compactKey.frame.height) / 2)
    findBar.fit(width: min(FindBarView.width, max(0, page.width - 16)))
    findBar.frame.origin = NSPoint(
      x: max(page.minX + 8, page.maxX - 8 - findBar.frame.width), y: page.minY + 8)
    focusContext?.refresh()
    placeApproval()
    phoneChip.frame.origin = NSPoint(
      x: (bounds.width - 48 - phoneChip.frame.width).rounded(),
      y: (54 - phoneChip.frame.height / 2).rounded())
    activity.frame = bounds
    launcher.frame = bounds
    if landing { camera?.app.applyPresentation(settling: true) }
  }
}
