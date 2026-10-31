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
    generation += 1
    defersFocus = true
    run(commit)
    guard app.presentation == .focused else {
      defersFocus = false
      return app.applyPresentation()
    }
    root.container.show(nil)
    fly(node: node, from: start, to: root.pageRect, toPage: true)
  }

  /// The page to the overview. `commit` switches the presentation, which hides the live view.
  func toOverview(of node: String?, commit: () -> Void) {
    guard let root = app.root, let node else { return commit() }
    let start = flightRect ?? root.pageRect
    generation += 1
    defersFocus = false
    run(commit)
    guard let destination = root.canvasView?.overviewCardRect(of: node) else { return cancel() }
    fly(node: node, from: start, to: destination, toPage: false)
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
    let landing = defersFocus
    cancel()
    return landing
  }

  private func fly(node: String, from: CGRect?, to: CGRect, toPage: Bool) {
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
