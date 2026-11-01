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

/// The identity row, the focused page's context and its caption: everything that gives way when a
/// page fills the window, so it fades and hides as one. It answers hits only through its parts.
final class PageChromeView: NSView {
  var passesHits = true
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard passesHits, !isHidden else { return nil }
    let local = convert(point, from: superview)
    return subviews.reversed().lazy.compactMap { $0.hitTest(local) }.first
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
  let orb = ThinkingOrbView()
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
  /// Hidden in the model, still fading out on screen.
  private var noticeLeaving = false
  let mark = NSImageView()
  let wordmark = NSTextField(labelWithString: "Photon")
  private let compactChip = FlippedView()
  private let compactKey = NSTextField(labelWithString: "⌘T")
  /// The one line on a first, empty canvas; hidden for good once a page exists.
  let hint = NSTextField(labelWithString: "")
  /// Appears at the top right while the pointer is there in Full window.
  let exitControl = ChromeButton(
    symbol: "arrow.down.right.and.arrow.up.left", label: "Exit Full Window", side: 28, glyph: 14)
  let chrome = PageChromeView()
  /// The focused page fills the window below the title bar; set by the app, never by a layout. The
  /// chrome's model is final at once, and a move fades what is on screen toward it.
  var fillsWindow = false {
    didSet {
      guard fillsWindow != oldValue else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      chrome.layer?.opacity = fillsWindow ? 0 : 1
      CATransaction.commit()
      chrome.passesHits = !fillsWindow
      if !fillsWindow { chrome.isHidden = false }
      showExitControl(false)
      layoutChildren()
    }
  }
  /// A click on bare window beside the focused page.
  var onEmptyClick: (() -> Void)?
  var onExitFullWindow: (() -> Void)?

  override var isFlipped: Bool { true }

  /// Ivory over the live pages while a page changes size under a move, so no half-laid-out page
  /// shows.
  let backdrop = FlightView()

  /// Once nothing fades any more, the chrome is out of the window for good while a page fills it.
  func settleFillChrome() { chrome.isHidden = fillsWindow }

  /// What the chrome shows now, a fade in progress included.
  var chromeOpacity: Float {
    chrome.layer.flatMap { (Motion.current($0, "opacity") as? NSNumber)?.floatValue } ?? 1
  }

  /// Native full screen has no title bar; otherwise a page filling the window starts below it.
  var titleBarInset: Double {
    guard let window, !window.styleMask.contains(.fullScreen) else { return 0 }
    return max(0, window.frame.height - window.contentLayoutRect.height)
  }

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
    notice.wantsLayer = true
    notice.layer?.opacity = 0
    notice.setAccessibilityElement(false)
    hint.textColor = Design.muted
    hint.alignment = .center
    hint.lineBreakMode = .byWordWrapping
    hint.maximumNumberOfLines = 2
    hint.isHidden = true
    hint.wantsLayer = true
    exitControl.isHidden = true
    exitControl.wantsLayer = true
    exitControl.toolTip = "Exit Full Window"
    compactKey.textColor = Design.muted
    compactChip.addSubview(compactKey)
    applyTextScale()
    for view in [mark, wordmark] {
      view.setAccessibilityElement(false)
      view.wantsLayer = true
    }
    chrome.wantsLayer = true
    chrome.setAccessibilityElement(false)
    backdrop.layer?.backgroundColor = Design.canvas.cgColor
    backdrop.isHidden = true
    for view in [mark, wordmark, caption] as [NSView] { chrome.addSubview(view) }
    exitControl.onClick = { [weak self] in self?.onExitFullWindow?() }
    for view in [
      container, backdrop, chrome, notice, hint, commandButton, compactChip, findBar, exitControl,
      approvalCard, phoneChip, activity, launcher, orb,
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
    hint.font = Fonts.ui(14)
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
    let onCaption =
      !caption.isHidden && caption.frame.contains(convert(event.locationInWindow, from: nil))
    if !fillsWindow, !onCaption { onEmptyClick?() }
  }

  // MARK: Pointer

  /// Where the pointer reveals the exit control while a page fills the window.
  var exitZone: NSRect {
    NSRect(x: bounds.width - 160, y: 0, width: 160, height: titleBarInset + 72)
  }

  /// The pointer moved inside the window, really or by a hook. What appears on hover is decided
  /// here, whichever view the pointer is over.
  func pointerMoved(to point: NSPoint) {
    showExitControl(fillsWindow && exitZone.contains(point))
    caption.setControlShown(!fillsWindow && caption.frame.contains(point))
    canvasView?.pointerMoved(to: point)
  }

  private func showExitControl(_ shown: Bool) {
    guard exitControl.isHidden == shown else { return }
    exitControl.isHidden = !shown
    guard shown, let layer = exitControl.layer else { return }
    layer.opacity = 1
    guard cameraIdle else { return }
    MotionLedger.shared.start(
      .buttonFade, target: "exitControl",
      [
        .init(
          layer: layer, key: "reveal.fade",
          animation: Motion.ease(
            "opacity", from: 0, to: 1,
            duration: MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.fadeSmall))
      ])
  }

  // MARK: First-run hint

  func setHint(_ text: String?) {
    hint.stringValue = text ?? ""
    hint.isHidden = text == nil
    layoutHint()
  }

  /// Centred on the empty canvas, clear of the title above and of the legend and button below.
  private func layoutHint() {
    guard !hint.isHidden else { return }
    let width = min(bounds.width - 96, 640 * Fonts.scale)
    let size =
      hint.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000))
      ?? .zero
    hint.frame = NSRect(
      x: ((bounds.width - width) / 2).rounded(), y: (bounds.height / 2 - size.height / 2).rounded(),
      width: width, height: size.height.rounded(.up))
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
    chrome.addSubview(focus, positioned: .below, relativeTo: mark)
    addSubview(flightView, positioned: .above, relativeTo: chrome)
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

  /// A short message in the identity row, clear of the page. A hidden notice has opacity 0.
  func showNotice(_ text: String?) {
    noticeTimer?.cancel()
    guard let text else {
      hideNotice()
      return
    }
    noticeLeaving = false
    notice.stringValue = text
    notice.isHidden = false
    notice.sizeToFit()
    layoutChildren()
    fadeNotice(to: 1)
    noticeTimer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      self?.showNotice(nil)
    }
  }

  private func hideNotice() {
    guard !notice.isHidden, !noticeLeaving else { return }
    noticeLeaving = true
    fadeNotice(to: 0) { [weak self] in self?.finishNotice() }
  }

  private func finishNotice() {
    noticeLeaving = false
    MotionLedger.shared.cancel(.notice)
    notice.layer?.opacity = 0
    notice.stringValue = ""
    notice.isHidden = true
    notice.sizeToFit()
    layoutChildren()
  }

  /// The camera's own move or landing already carries a notice that appears with it, so a fade
  /// starts only on an idle canvas: it would hold the overview toggle's settle otherwise.
  private var cameraIdle: Bool { camera.map { !$0.isMoving && $0.layerKind == nil } ?? true }

  /// What Muse is doing, beside the command button; nil hides the orb. Fades wait for an idle
  /// camera, like the notice.
  func setOrb(_ next: (run: String, working: Bool)?) {
    if let next {
      orb.show(run: next.run, working: next.working, animated: cameraIdle)
    } else {
      orb.hide(animated: cameraIdle)
    }
  }

  private func fadeNotice(to target: Float, then done: (() -> Void)? = nil) {
    guard let layer = notice.layer else { return }
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 0
    layer.opacity = target
    guard cameraIdle, from != target else {
      MotionLedger.shared.cancel(.notice)
      done?()
      return
    }
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.fadeSmall
    MotionLedger.shared.start(
      .notice, target: "notice",
      [
        .init(
          layer: layer, key: "notice.fade",
          animation: Motion.ease("opacity", from: from, to: target, duration: duration))
      ]
    ) { finished in
      if finished { done?() }
    }
  }

  var noticeText: String? { notice.isHidden || noticeLeaving ? nil : notice.stringValue }
  var noticeFrame: NSRect { notice.frame }

  private var compactButton = false
  /// The approval card needs the strip the command button sits in.
  private var approvalCovers = false

  func setCommandButtonCompact(_ compact: Bool) {
    compactButton = compact
    commandButton.isHidden = compact || approvalCovers
    compactChip.isHidden = !compact
  }

  /// The button fades while an approval card covers it and comes back with the card gone. The
  /// model is final at once; only what is on screen follows (hit tests included: the card overlaps
  /// the button anyway). Compact, the chip stands in and nothing animates.
  private func setApprovalCovers(_ covers: Bool) {
    guard covers != approvalCovers else { return }
    approvalCovers = covers
    guard let layer = commandButton.layer else { return }
    let from = (Motion.current(layer, "opacity") as? NSNumber)?.floatValue ?? 1
    let target: Float = covers ? 0 : 1
    layer.opacity = target
    guard !compactButton else { return }
    commandButton.isHidden = false
    guard cameraIdle else {
      MotionLedger.shared.cancel(.buttonFade)
      commandButton.isHidden = covers
      return
    }
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.fadeSmall
    MotionLedger.shared.start(
      .buttonFade, target: "commandButton",
      [
        .init(
          layer: layer, key: "cover.fade",
          animation: Motion.ease("opacity", from: from, to: target, duration: duration))
      ]
    ) { [weak self] finished in
      guard let self, finished else { return }
      commandButton.isHidden = compactButton || approvalCovers
    }
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
    setApprovalCovers(false)
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
    // A page that fills the window leaves nothing below it: the card rises over its bottom edge.
    let covering = anchor.focused && fillsWindow
    let wanted: CGFloat
    let room: CGFloat
    if covering {
      (wanted, room) = (min(target.width, 632 * scale), target.height - 16)
    } else if anchor.focused {
      (wanted, room) = (target.width, bounds.height - 12 - target.maxY)
    } else {
      wanted = max(target.width, 320 * scale)
      room = max(
        80 * scale,
        (compactButton ? compactChip.frame.minY : commandButton.frame.minY) - 16
          - target.minY - PageGraph.nodeHeight * CGFloat(canvasView?.zoomLevel ?? 1))
    }
    let width = min(bounds.width - 16, wanted)
    let height = approvalCard.fit(width: width, maxHeight: room)
    let x = min(
      max(8, anchor.focused && !covering ? target.minX : target.midX - width / 2),
      bounds.width - 8 - width)
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
    setApprovalCovers(
      frame.maxY + 8 > commandButton.frame.minY && frame.minX < commandButton.frame.maxX
        && frame.maxX > commandButton.frame.minX)
    return true
  }

  var compactChipVisible: Bool { !compactChip.isHidden }

  func layoutChildren() {
    mark.frame = NSRect(x: 48, y: 45.6, width: 24, height: 16.8)
    wordmark.sizeToFit()
    wordmark.frame.origin = NSPoint(x: 80, y: 41)
    canvasView?.frame = bounds
    chrome.frame = bounds
    backdrop.frame = bounds
    focusContext?.frame = bounds
    flightView.frame = bounds
    container.frame = bounds
    focusLayout = FocusLayout.make(
      size: bounds.size, left: context.left.count, right: context.right.count,
      scale: Fonts.scale, fillInset: fillsWindow ? titleBarInset : nil)
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
    // The caption stays where it was while it fades out with the rest of the chrome.
    if !fillsWindow { caption.frame = focusLayout.caption }
    exitControl.frame.origin = NSPoint(
      x: bounds.width - 12 - exitControl.frame.width, y: page.minY + 8)
    layoutHint()
    commandButton.frame.origin = NSPoint(
      x: ((bounds.width - CommandButton.width) / 2).rounded(),
      y: bounds.height - 16 - CommandButton.height)
    let chip = NSSize(width: 64 * Fonts.scale, height: 40 * Fonts.scale)
    compactChip.frame = NSRect(
      x: ((bounds.width - chip.width) / 2).rounded(), y: bounds.height - 20 - chip.height,
      width: chip.width, height: chip.height)
    compactKey.frame.origin = NSPoint(
      x: (chip.width - compactKey.frame.width) / 2, y: (chip.height - compactKey.frame.height) / 2)
    let anchor = compactButton ? compactChip.frame : commandButton.frame
    orb.frame = NSRect(
      x: anchor.minX - 8 - ThinkingOrbView.size, y: anchor.midY - ThinkingOrbView.size / 2,
      width: ThinkingOrbView.size, height: ThinkingOrbView.size)
    findBar.fit(width: min(FindBarView.width, max(0, page.width - 16)))
    // Below the exit control, which sits in the same corner of a page that fills the window.
    findBar.frame.origin = NSPoint(
      x: max(page.minX + 8, page.maxX - 8 - findBar.frame.width),
      y: page.minY + (fillsWindow ? 44 : 8))
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
