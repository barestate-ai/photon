import AppKit
import BarestateCore

/// Hosts the layer a move flies: above the pages and the overview, under the command button.
final class FlightView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError("not used") }
}

/// The move between the overview and a page. A windowed CEF view cannot be scaled, so a cached
/// preview of the page (or a plain card when there is none) is what travels: it springs between
/// the node's card and the page's rect while the live view stays hidden at its final frame. The
/// live view is shown once, when the move lands, and the preview fades off it. Leaving a page
/// hides the live view first and flies the preview onto the node.
///
/// A move can be interrupted at any frame: the next one starts from where the layer is on screen
/// and the one it replaces never lands.
@MainActor
final class CameraTransition {
  unowned let app: AppController
  private let ledger = MotionLedger.shared
  private let layer = CALayer()
  private(set) var generation = 0
  private(set) var layerKind: String?
  /// From the start of a move into a page until it lands: the live view stays hidden.
  private(set) var defersFocus = false
  /// From the start of a move to Full window or back until it ends: the page is on screen, but the
  /// keyboard goes to it only when the move lands.
  private var filling = false
  /// While a move's `commit` runs: the layout it causes belongs to the move being set up.
  private var committing = false

  init(app: AppController) {
    self.app = app
    layer.masksToBounds = true
    layer.contentsGravity = .resize
    layer.minificationFilter = .trilinear
    layer.backgroundColor = Design.surface.cgColor
    layer.isHidden = true
  }

  var isMoving: Bool { ledger.running(.camera) }

  /// The layer's rect on screen right now, in window points.
  var flightRect: CGRect? {
    guard layerKind != nil, let page = app.root?.pageRect else { return nil }
    let live = layer.presentation() ?? layer
    let t = live.transform
    let size = CGSize(width: page.width * t.m11, height: page.height * t.m22)
    return CGRect(
      x: page.midX + t.m41 - size.width / 2, y: page.midY + t.m42 - size.height / 2,
      width: size.width, height: size.height)
  }

  // MARK: Moves

  /// Overview to `node`'s page. `commit` makes the page active; it runs with the live view's
  /// reveal deferred to the landing.
  func toPage(of node: String, commit: () -> Void) {
    guard let root = app.root, app.presentation == .overview || isMoving else {
      return commit()
    }
    let start = flightRect ?? root.canvasView?.overviewCardRect(of: node)
    let chromeFrom = root.chromeOpacity
    generation += 1
    defersFocus = true
    run(commit)
    guard app.presentation == .focused else {
      defersFocus = false
      return app.applyPresentation()
    }
    root.container.show(nil)
    fly(node: node, from: start, to: root.pageRect, toPage: true, chromeFrom: chromeFrom)
  }

  /// The page to the overview. `commit` switches the presentation, which hides the live view.
  func toOverview(of node: String?, commit: () -> Void) {
    guard let root = app.root, let node else { return commit() }
    let start = flightRect ?? root.pageRect
    let chromeFrom = root.chromeOpacity
    generation += 1
    defersFocus = false
    run(commit)
    guard let destination = root.canvasView?.overviewCardRect(of: node) else { return cancel() }
    fly(node: node, from: start, to: destination, toPage: false, chromeFrom: chromeFrom)
  }

  /// The focused page to Full window and back. The live view takes its final frame at once under
  /// an ivory backdrop, the page's last look flies between the two frames above it, and both fade
  /// off together at the end: the page is revealed inside this one move, never by a second.
  func toFill(_ fill: Bool) {
    guard let root = app.root, let node = app.activeNodeId, let backdrop = root.backdrop.layer,
      let chrome = root.chrome.layer
    else { return }
    let start = flightRect ?? root.pageRect
    let chromeFrom = (Motion.current(chrome, "opacity") as? NSNumber)?.floatValue ?? 1
    generation += 1
    defersFocus = false
    filling = true
    ledger.cancel(.camera)
    run { app.fillsWindow = fill }
    let page = root.pageRect
    prepare(node: node, page: page)

    let spring = Motion.spring(
      .camera, keyPath: "transform",
      from: NSValue(caTransform3D: Self.transform(page, to: start)),
      to: NSValue(caTransform3D: CATransform3DIdentity))
    let (begin, end) = (fill ? Self.radius(start, page: page) : 0, fill ? 0 : Design.radiusControl)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = CATransform3DIdentity
    layer.cornerRadius = end
    layer.opacity = 0
    root.backdrop.isHidden = false
    backdrop.opacity = 0
    CATransaction.commit()

    // Held at full opacity until the move is nearly over, then gone by its end.
    func tail(_ from: Float) -> CAKeyframeAnimation {
      let cover = Motion.previewSwapCover / spring.duration
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      fade.values = [from, from, 0]
      fade.keyTimes = [0, NSNumber(value: max(0, 1 - cover)), 1]
      fade.timingFunctions = [Motion.easeOut, Motion.easeOut]
      fade.duration = spring.duration
      return fade
    }
    let chromeFade = Motion.ease(
      "opacity", from: chromeFrom, to: chrome.opacity,
      duration: fill ? Motion.cameraFade : Motion.columnsFade)
    let generation = generation
    ledger.start(
      .camera, target: node, generation: generation,
      [
        .init(layer: layer, key: "camera", animation: spring),
        .init(
          layer: layer, key: "camera.radius",
          animation: Motion.spring(.camera, keyPath: "cornerRadius", from: begin, to: end)),
        .init(layer: layer, key: "camera.cover", animation: tail(1)),
        .init(layer: backdrop, key: "camera.backdrop", animation: tail(1)),
        .init(layer: chrome, key: "fill.fade", animation: chromeFade),
      ]
    ) { [weak self] finished in
      guard let self, finished, generation == self.generation else { return }
      clear()
      app.applyPresentation(settling: true)
    }
    CATransaction.flush()
  }

  private func run(_ commit: () -> Void) {
    committing = true
    commit()
    committing = false
  }

  /// Ends any move at once on the final frame: a keyboard switch or a vanished destination
  /// must not leave a stale preview flying over the page that is now shown.
  func cancel() {
    generation += 1
    defersFocus = false
    ledger.cancel(.camera)
    ledger.cancel(.previewCrossfade)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    app.root?.canvasView?.layer?.opacity = 1
    for fade in chromeLayers { fade.opacity = 1 }
    CATransaction.commit()
    clear()
  }

  /// Ends a move before the live view changes size, so no CEF resize happens in flight. True when
  /// the move was heading into a page: the caller lands it once the new frame is in place.
  func settle() -> Bool {
    guard !committing, isMoving || defersFocus || layerKind != nil else { return false }
    let landing = defersFocus || filling
    cancel()
    return landing
  }

  private func fly(node: String, from: CGRect?, to: CGRect, toPage: Bool, chromeFrom: Float) {
    guard let root = app.root else { return }
    let page = root.pageRect
    let generation = generation
    let reduced = app.motionReduced
    let canvas = root.canvasView?.layer
    let canvasNow = ledger.running(.camera) ? Motion.current(canvas ?? layer, "opacity") : nil
    ledger.cancel(.previewCrossfade)
    prepare(node: node, page: page)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = Self.transform(page, to: reduced ? page : to)
    layer.cornerRadius = Self.radius(reduced ? page : to, page: page)
    canvas?.opacity = toPage && !reduced ? 0 : 1
    for fade in chromeLayers { fade.opacity = toPage ? 0 : 1 }
    CATransaction.commit()

    if reduced {
      ledger.settleAll()
      if toPage { land() } else { cover() }
      CATransaction.flush()
      return
    }
    let begin = from ?? page
    var parts: [MotionLedger.Part] = [
      .init(
        layer: layer, key: "camera",
        animation: Motion.spring(
          .camera, keyPath: "transform",
          from: NSValue(caTransform3D: Self.transform(page, to: begin)),
          to: NSValue(caTransform3D: Self.transform(page, to: to)))),
      .init(
        layer: layer, key: "camera.radius",
        animation: Motion.spring(
          .camera, keyPath: "cornerRadius", from: Self.radius(begin, page: page),
          to: Self.radius(to, page: page))),
    ]
    if let canvas {
      let fade =
        toPage
        ? Motion.ease(
          "opacity", from: canvasNow ?? 1, to: 0, duration: Motion.cameraFade)
        : Motion.ease(
          "opacity", from: canvasNow ?? 0, to: 1, duration: Motion.overviewFade,
          delay: Motion.overviewFadeDelay)
      parts.append(.init(layer: canvas, key: "camera.fade", animation: fade))
    }
    // The identity row goes with the overview into a page that fills the window, and comes back
    // with it.
    if let chrome = root.chrome.layer, chrome.opacity != chromeFrom {
      parts.append(
        .init(
          layer: chrome, key: "fill.fade",
          animation: Motion.ease(
            "opacity", from: chromeFrom, to: chrome.opacity,
            duration: toPage ? Motion.cameraFade : Motion.overviewFade)))
    }
    ledger.start(.camera, target: node, generation: generation, parts) { [weak self] finished in
      guard let self, finished, generation == self.generation else { return }
      if toPage { self.land() } else { self.clear() }
    }
    // The presentation layer reports the new move from the first read, not from the next commit.
    CATransaction.flush()
  }

  /// The move into a page ended: the live view takes over from the preview.
  private func land() {
    guard let root = app.root else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defersFocus = false
    app.applyPresentation(settling: true)
    root.canvasView?.layer?.opacity = 1
    CATransaction.commit()
    cover()
    guard !app.fillsWindow else { return }
    let duration = app.motionReduced ? Motion.reducedToggleFade : Motion.columnsFade
    for fade in chromeLayers {
      fade.opacity = 1
      ledger.start(
        .previewCrossfade, target: "context",
        [
          .init(
            layer: fade, key: "camera.context",
            animation: Motion.ease("opacity", from: 0, to: 1, duration: duration))
        ])
    }
  }

  /// The flying layer fades off whatever is under it, then goes.
  private func cover() {
    let generation = generation
    layer.opacity = 0
    ledger.start(
      .previewCrossfade, target: "swap", generation: generation,
      [
        .init(
          layer: layer, key: "camera.cover",
          animation: Motion.ease(
            "opacity", from: 1, to: 0,
            duration: app.motionReduced ? Motion.reducedToggleFade : Motion.previewSwapCover))
      ]
    ) { [weak self] finished in
      guard let self, finished, generation == self.generation else { return }
      self.clear()
    }
  }

  /// What appears with the page rather than with the move: its neighbours and its caption.
  private var chromeLayers: [CALayer] {
    [app.root?.focusContext.layer, app.root?.caption.layer].compactMap { $0 }
  }

  private func clear() {
    layer.removeFromSuperlayer()
    layerKind = nil
    filling = false
    app.root?.backdrop.isHidden = true
    app.root?.settleFillChrome()
  }

  // MARK: The flying layer

  private func prepare(node: String, page: CGRect) {
    guard let host = app.root?.flightView.layer else { return }
    if layer.superlayer !== host { host.addSublayer(layer) }
    layer.isHidden = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.bounds = CGRect(origin: .zero, size: page.size)
    layer.position = CGPoint(x: page.midX, y: page.midY)
    let image =
      app.canvas.previews.state(of: node) == .none
      ? nil : app.canvas.previews.preview(for: node)?.image
    layer.contents = image
    layerKind = image == nil ? "placeholder" : "preview"
    CATransaction.commit()
  }

  /// Scales about the layer's centre, then carries that centre onto `to`'s.
  static func transform(_ from: CGRect, to: CGRect) -> CATransform3D {
    let move = RectMotion(from: from, to: to)
    return CATransform3DConcat(
      CATransform3DMakeScale(move.scaleX, move.scaleY, 1),
      CATransform3DMakeTranslation(move.translateX, move.translateY, 0))
  }

  /// A corner radius that looks like the card's once the layer is scaled onto `rect`.
  static func radius(_ rect: CGRect, page: CGRect) -> CGFloat {
    let move = RectMotion(from: page, to: rect)
    return Design.radiusControl / max((move.scaleX + move.scaleY) / 2, 0.01)
  }
}
