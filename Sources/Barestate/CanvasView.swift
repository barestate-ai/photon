import AppKit
import BarestateCore

/// The overview: every page of the graph as a card on a pannable, zoomable canvas, with the
/// trails between them, the canvas title and the legend. It draws only what the graph and the
/// preview cache hold, and it changes the graph only through `PageCanvas`.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
  static let revealMargin = 48.0
  /// Clear of the canvas title above the pages and the command button below them.
  static let fitMargin = 112.0
  /// Framing never magnifies: a lone card stays card-sized instead of filling the window.
  static let fitZoom = 1.0
  /// A press that moves less than this is a click.
  static let dragThreshold = 4.0
  static let phasedIdle = Duration.seconds(2)
  /// More pages than this appearing at once are a restored session, not arrivals.
  static let enteringLimit = 8

  unowned let app: AppController
  let titleField = NSTextField()
  let legend = LegendView()
  let zoomPill = ZoomPillView()
  /// The node elements are rebuilt when a client asks for the children, so a change is announced.
  private(set) var selected: String? {
    didSet {
      if selected != oldValue {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
      }
    }
  }

  private let edgeLayer = CALayer()
  private let nodeLayer = CALayer()
  private(set) var cards: [String: NodeCard] = [:]
  private(set) var trails: [String: CAShapeLayer] = [:]
  /// Ids of the trail-flow loops running now.
  private var flowing: Set<String> = []
  private var renderScale: CGFloat = 0
  private var settling: Task<Void, Never>?
  private var gestureEnd: Task<Void, Never>?
  private var gesturing = false
  private var still = Date.distantPast
  private var drag: Drag?
  private var pan: Pan?
  private var reverting = false
  /// Set once a refresh has drawn the overview: cards and trails that appear after that enter,
  /// including those made while a page was in front. What the first draw finds (a restored
  /// session) is simply there.
  private var hasDrawn = false
  private(set) var hovered: String?
  /// A pinch past the zoom limits: the unclamped zoom, and where the pinch is anchored.
  private var overshoot: (raw: Double, anchor: CGPoint)?
  /// Until the person moves the camera, it keeps every page in view and centred. Nil until the
  /// first page shows, then true only for a canvas whose camera was never saved or set.
  private var autoFrame: Bool?

  private struct Drag {
    let id: String
    let start: CGPoint
    let origin: CGPoint
    let zoom: Double
    var moved = false
  }

  /// A press on empty canvas: the camera follows the pointer from where it started.
  private struct Pan {
    let start: CGPoint
    let origin: Viewport
    var moved = false
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(app: AppController) {
    self.app = app
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(edgeLayer)
    layer?.addSublayer(nodeLayer)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.focusRingType = .none
    titleField.font = Fonts.serif(34)
    titleField.textColor = Design.ink
    titleField.lineBreakMode = .byTruncatingTail
    titleField.delegate = self
    titleField.setAccessibilityLabel("Canvas title")
    titleField.setAccessibilityRole(.textField)
    setAccessibilityEnabled(true)
    addSubview(titleField)
    addSubview(legend)
    addSubview(zoomPill)
    zoomPill.onZoomOut = { [weak self] in self?.zoom(by: 1 / Viewport.zoomStep) }
    zoomPill.onZoomIn = { [weak self] in self?.zoom(by: Viewport.zoomStep) }
    zoomPill.onZoomToFit = { [weak self] in self?.zoomToFit() }
    titleField.wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // MARK: Layout

  /// 48 pt from the edge in a wide window, less in a narrow one.
  private var inset: CGFloat { bounds.width >= 1200 ? 48 : (bounds.width >= 900 ? 32 : 24) }

  override func layout() {
    super.layout()
    // The design's 34 pt line box starts at y 84; the font's own line is taller, so centre it there.
    let line = ceil(titleField.cell?.cellSize.height ?? 34)
    titleField.frame = NSRect(x: inset, y: 84 - (line - 34) / 2, width: 320, height: line)
    // Beside the command button, or above it when a larger text scale makes them meet.
    let clear = (bounds.width - CommandButton.width) / 2 - 8
    let above = inset + max(legend.frame.width, zoomPill.frame.width) > clear
    let legendY =
      above
      ? bounds.height - 16 - CommandButton.height - 8 - LegendView.height
      : bounds.height - 32 - LegendView.height
    legend.frame.origin = NSPoint(x: inset, y: legendY)
    // Where the legend would be even while it is hidden, so the pill never moves with it.
    zoomPill.frame.origin = NSPoint(x: inset, y: legendY - 12 - zoomPill.frame.height)
    refresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    renderScale = 0
    refresh()
  }

  // MARK: State

  private var graph: PageGraph { app.canvas.graph }
  private var viewport: Viewport { graph.viewport }

  /// The node the keys act on: the one last chosen, else the active page's.
  var selection: String? {
    if let selected, graph.nodes.contains(where: { $0.id == selected }) { return selected }
    return app.activeNodeId
  }

  func select(_ id: String?) {
    selected = id
    refresh()
  }

  /// The active page changed: the selection goes back to it, and the overview brings it into view.
  func followActive(reveal: Bool) {
    selected = nil
    if reveal, let node = graph.nodes.first(where: { $0.id == app.activeNodeId }) {
      setViewport(viewport.revealing(node.frame, in: bounds.size, margin: Self.revealMargin))
    }
    refresh()
  }

  /// The person (or a test standing in for them) now owns the camera.
  func takeCamera() { autoFrame = false }

  private func setViewport(_ next: Viewport) {
    if next != viewport { autoFrame = false }
    setCamera(next)
  }

  private func setCamera(_ next: Viewport) {
    app.canvas.edit { graph in
      guard graph.viewport != next else { return false }
      graph.viewport = next
      return true
    }
  }

  // MARK: Drawing

  /// ⌘R is a keyboard path that never animates, yet the reload marks the preview stale a moment
  /// later; cards draw in place until that has settled.
  func holdStill() { still = Date().addingTimeInterval(1) }

  func refresh() {
    guard !isHidden, bounds.width > 0, let layer else {
      for card in cards.values { card.hideMuse() }
      setFlowing([])
      return
    }
    let scale = window?.backingScaleFactor ?? 2
    frameContentIfFollowing()
    let camera = viewport
    if renderScale == 0 { renderScale = scale * max(1, ceil(camera.zoom * 2) / 2) }
    let nodes = graph.nodes
    let current = app.activeNodeId
    let chosen = selection
    let onscreen = camera.visibleRect(in: bounds.size).insetBy(
      dx: -PageGraph.nodeWidth, dy: -PageGraph.nodeHeight)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    edgeLayer.frame = layer.bounds
    nodeLayer.frame = layer.bounds

    let arriving = nodes.filter { cards[$0.id] == nil }.count
    let entering = hasDrawn && arriving <= Self.enteringLimit && !app.camera.isMoving
    // A preview that lands while a move covers the cards is swapped under it: fading it in would
    // keep the arriving overview from settling.
    let animated = entering && !gesturing && Date() >= still && app.camera.layerKind == nil
    var live = Set<String>()
    for node in nodes {
      live.insert(node.id)
      let isNew = cards[node.id] == nil
      let card = cards[node.id] ?? makeCard(node.id)
      let visible = onscreen.intersects(node.frame)
      card.layer.isHidden = !visible
      guard visible else {
        card.dropImage()
        continue
      }
      card.layer.position = camera.screen(CGPoint(x: node.x, y: node.y), in: bounds.size)
      let held = heldScale(node.id)
      card.layer.setAffineTransform(
        CGAffineTransform(scaleX: camera.zoom * held, y: camera.zoom * held))
      card.layer.zPosition = node.id == chosen || drag?.id == node.id ? 1 : 0
      if isNew && entering { enter(card, node: node, camera: camera) }
      let state = app.canvas.previews.state(of: node.id)
      let image = state == .none ? nil : app.canvas.previews.preview(for: node.id)?.image
      card.apply(
        NodeCard.Look(
          node, state: state, hasImage: image != nil, current: node.id == current,
          selected: node.id == chosen, scale: renderScale, runs: app.runs.runs(ownedBy: node.tabId)),
        newImage: image.flatMap { card.isShowing($0) ? nil : $0 }, animated: animated)
    }
    for id in cards.keys where !live.contains(id) {
      let gone = cards.removeValue(forKey: id)
      gone?.hideMuse()
      gone?.layer.removeFromSuperlayer()
    }
    drawTrails(camera, entering: entering)
    hasDrawn = true
    legend.show(legendItems)
    zoomPill.show(percent: camera.zoomPercent)
    titleField.stringValue =
      titleField.currentEditor() == nil ? graph.title : titleField.stringValue
  }

  private func frameContentIfFollowing() {
    if autoFrame == nil, !graph.nodes.isEmpty { autoFrame = !graph.hasRestoredCamera }
    guard autoFrame == true else { return }
    let fit = Viewport.fitting(
      graph.nodes.map(\.frame), in: bounds.size, margin: Self.fitMargin, maxZoom: Self.fitZoom)
    if fit != viewport { setCamera(fit) }
  }

  private func makeCard(_ id: String) -> NodeCard {
    let card = NodeCard(id: id)
    nodeLayer.addSublayer(card.layer)
    cards[id] = card
    return card
  }

  private var legendItems: [LegendView.Item] {
    let kinds = Set(graph.edges.map(\.kind))
    var items: [LegendView.Item] = []
    if !kinds.isDisjoint(with: [.openedFrom, .navigatedFrom]) { items.append(.yourTrail) }
    if kinds.contains(.museUsed) { items.append(.muse) }
    return items
  }

  private func drawTrails(_ camera: Viewport, entering: Bool) {
    var live = Set<String>()
    let byId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    let visible = camera.visibleRect(in: bounds.size)
    for edge in graph.edges {
      guard let from = byId[edge.from], let to = byId[edge.to] else { continue }
      let key = "\(edge.from)>\(edge.to)>\(edge.kind.rawValue)>\(edge.runId ?? "")"
      live.insert(key)
      let isNew = trails[key] == nil
      let line = trails[key] ?? makeTrail(key)
      let route = EdgeRoute.make(from: drawnFrame(from), to: drawnFrame(to), bow: Trail.bow)
      line.path = Trail.path(route) { camera.screen($0, in: bounds.size) }
      Trail.style(line, kind: edge.kind, zoom: camera.zoom)
      if isNew && entering && visible.intersects(from.frame) && visible.intersects(to.frame) {
        draw(line, key: key)
      }
    }
    for key in trails.keys where !live.contains(key) {
      trails.removeValue(forKey: key)?.removeFromSuperlayer()
    }
    flowNewestTrails(camera)
  }

  /// The card as it is drawn: a lifted card is larger about its centre, and its trails meet that
  /// edge.
  private func drawnFrame(_ node: PageNode) -> CGRect {
    let frame = node.cardFrame
    guard drag?.id == node.id, drag?.moved == true, !app.motionReduced else { return frame }
    let lift = Double(Motion.pickupScale)
    return CGRect(
      x: node.x + (frame.minX - node.x) * lift, y: node.y + (frame.minY - node.y) * lift,
      width: frame.width * lift, height: frame.height * lift)
  }

  /// The Muse trail into the page each working run used most recently drifts, ambient, until the
  /// run ends. The loop id carries the zoom, which sets the dash period, so a zoom change
  /// restarts it once.
  private func flowNewestTrails(_ camera: Viewport) {
    var wanted: [String: (key: String, run: String)] = [:]
    if !app.motionReduced {
      for run in app.runs.runs where run.state == .running {
        let pages = run.steps.reversed().filter { $0.state != "failed" }.compactMap(\.tabId)
        guard let edge = graph.newestTrail(run: run.id, pages: pages) else { continue }
        let key = "\(edge.from)>\(edge.to)>\(edge.kind.rawValue)>\(run.id)"
        wanted["trail:\(key)@\(String(format: "%.2f", camera.zoom))"] = (key, run.id)
      }
    }
    // Stop the obsolete loops first: a replacement shares the layer and key, so stopping it
    // afterwards would remove the animation just added.
    let ids = Set(wanted.keys)
    for id in flowing.subtracting(ids) { MotionLedger.shared.stopLoop(id, settle: false) }
    for (id, trail) in wanted where !flowing.contains(id) {
      guard let line = trails[trail.key] else { continue }
      MotionLedger.shared.startLoop(
        .trailFlow, id: id, target: trail.key, runId: trail.run, surface: "overview", layer: line,
        key: "trail.flow", animation: Trail.flow(zoom: camera.zoom))
    }
    flowing = ids
  }

  private func setFlowing(_ ids: Set<String>) {
    for id in flowing.subtracting(ids) { MotionLedger.shared.stopLoop(id, settle: false) }
    flowing = ids
  }

  // MARK: Motion

  /// A new page arrives from the page it was opened from, settling into its place.
  private func enter(_ card: NodeCard, node: PageNode, camera: Viewport) {
    let layer = card.layer
    let reduced = app.motionReduced
    var parts: [MotionLedger.Part] = []
    if !reduced {
      let source = graph.edges.first { $0.to == node.id }.flatMap { edge in
        graph.nodes.first { $0.id == edge.from }
      }
      let scale = camera.zoom * Motion.enterScale
      var begin = CATransform3DMakeScale(scale, scale, 1)
      if let source {
        begin.m41 = (source.x - node.x) * Motion.enterTravelFraction * camera.zoom
        begin.m42 = (source.y - node.y) * Motion.enterTravelFraction * camera.zoom
      }
      parts.append(
        .init(
          layer: layer, key: "enter.move",
          animation: Motion.ease(
            "transform", from: NSValue(caTransform3D: begin),
            to: NSValue(caTransform3D: layer.transform), duration: Motion.nodeEnter)))
    }
    parts.append(
      .init(
        layer: layer, key: "enter.fade",
        animation: Motion.ease(
          "opacity", from: 0, to: 1, duration: reduced ? Motion.reducedFade : Motion.nodeEnter)))
    MotionLedger.shared.start(.nodeEnter, target: node.id, parts)
  }

  /// A trail reaches its page along its path, once, when it is first recorded.
  private func draw(_ line: CAShapeLayer, key: String) {
    let reduced = app.motionReduced
    let animation =
      reduced
      ? Motion.ease("opacity", from: 0, to: 1, duration: Motion.reducedFade)
      : Motion.ease(
        "strokeEnd", from: 0, to: 1, duration: Motion.trailDraw, delay: Motion.trailDelay)
    MotionLedger.shared.start(
      .trailDraw, target: key, [.init(layer: line, key: "draw", animation: animation)])
  }

  /// How far a held card is scaled: pressed a little, lifted a little once it moves.
  private func heldScale(_ id: String) -> CGFloat {
    guard let held = drag, held.id == id, !app.motionReduced else { return 1 }
    return held.moved ? Motion.pickupScale : Motion.nodePressScale
  }

  /// Carries the card to the look `drag` now asks for. Pointer-driven, so the position itself
  /// is never animated.
  private func animateHold(_ id: String, _ kind: MotionLedger.Kind) {
    guard let card = cards[id] else { return }
    let layer = card.layer
    let body = card.cardLayer
    let reduced = app.motionReduced
    let fromScale = (layer.presentation() ?? layer).transform
    let fromShadow = (body.presentation() ?? body).shadowOpacity
    let held = heldScale(id)
    let toScale = CATransform3DMakeScale(viewport.zoom * held, viewport.zoom * held, 1)
    let toShadow = drag?.id == id && drag?.moved == true ? Motion.pickupShadowOpacity : 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = toScale
    body.shadowOpacity = toShadow
    CATransaction.commit()
    var parts: [MotionLedger.Part] = []
    if !reduced {
      let to = NSValue(caTransform3D: toScale)
      let from = NSValue(caTransform3D: fromScale)
      let move =
        kind == .nodeDrop
        ? Motion.spring(.drop, keyPath: "transform", from: from, to: to, cap: 0.3)
        : Motion.ease(
          "transform", from: from, to: to,
          duration: kind == .nodePickup
            ? Motion.pickup : (held == 1 ? Motion.pressRelease : Motion.press))
      parts.append(.init(layer: layer, key: "hold.move", animation: move))
    }
    if fromShadow != toShadow {
      let duration =
        reduced ? Motion.reducedFade : (kind == .nodeDrop ? Motion.dropShadow : Motion.pickup)
      parts.append(
        .init(
          layer: body, key: "hold.shadow",
          animation: Motion.ease(
            "shadowOpacity", from: fromShadow, to: toShadow, duration: duration)
        ))
    }
    if !parts.isEmpty { MotionLedger.shared.start(kind, target: id, parts) }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    pointerMoved(to: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) { hover(nil) }

  /// The pointer, really or by a hook, is at `point`: the card under it is hovered, and the cursor
  /// says what a press does there. A card opens on a click (pointing hand); the empty canvas pans
  /// (open hand); a card being dragged or the canvas being panned is held (closed hand).
  func pointerMoved(to point: CGPoint) {
    guard !isHidden, !zoomPill.frame.contains(point) else {
      cursor = .arrow
      return hover(nil)
    }
    let id = drag == nil && pan == nil && !gesturing ? nodeId(at: point) : nil
    hover(id)
    cursor =
      drag?.moved == true || pan != nil ? .closedHand : (id == nil ? .openHand : .pointingHand)
    cursor.set()
  }

  /// What the pointer last showed over the overview.
  private(set) var cursor = NSCursor.arrow

  var cursorName: String {
    switch cursor {
    case .pointingHand: "pointing-hand"
    case .openHand: "open-hand"
    case .closedHand: "closed-hand"
    default: "arrow"
    }
  }

  private func hover(_ id: String?) {
    guard id != hovered else { return }
    if let old = hovered { cards[old]?.setHover(false) }
    hovered = id
    if let id { cards[id]?.setHover(true) }
  }

  private func makeTrail(_ key: String) -> CAShapeLayer {
    let line = Trail.makeLayer()
    edgeLayer.addSublayer(line)
    trails[key] = line
    return line
  }

  /// Text is rasterised at the zoom it is shown at, once the camera has stopped moving.
  private func settleRendering() {
    settling?.cancel()
    settling = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard let self else { return }
      self.renderScale = 0
      self.refresh()
    }
  }

  // MARK: Camera

  /// A trackpad gesture announces its end, so the pause of a held finger must not end it; the
  /// idle timeout is only the guard against an end that never comes. Events with no phase (a
  /// wheel mouse, the hooks) end after a short idle.
  private func holdGesture(idle: Duration = .milliseconds(250)) {
    if !gesturing {
      gesturing = true
      app.canvas.gesture(true)
    }
    gestureEnd?.cancel()
    gestureEnd = Task { [weak self] in
      do { try await Task.sleep(for: idle) } catch { return }
      self?.releaseGesture()
    }
  }

  private func releaseGesture() {
    gestureEnd?.cancel()
    guard gesturing, drag?.moved != true, pan?.moved != true else { return }
    gesturing = false
    endStretch()
    app.canvas.gesture(false)
  }

  func scroll(dx: Double, dy: Double, idle: Duration = .milliseconds(250)) {
    holdGesture(idle: idle)
    setViewport(viewport.panned(byScreen: CGSize(width: dx, height: dy)))
  }

  func magnify(by factor: Double, at point: CGPoint, idle: Duration = .milliseconds(250)) {
    holdGesture(idle: idle)
    let range = Viewport.zoomRange
    let raw = (overshoot?.raw ?? viewport.zoom) * factor
    let target = min(max(raw, range.lowerBound), range.upperBound)
    setViewport(viewport.zoomed(by: target / viewport.zoom, around: point, in: bounds.size))
    settleRendering()
    stretch(raw: raw, target: target, at: point)
  }

  /// Past a zoom limit the picture gives a little, resisting, and springs back when the pinch
  /// ends. The stored zoom stays clamped; only the layers stretch.
  private func stretch(raw: Double, target: Double, at point: CGPoint) {
    guard raw != target, !app.motionReduced else { return endStretch() }
    overshoot = (raw, point)
    let shown = RubberBand.shown(raw, in: Viewport.zoomRange) / target
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    var transform = CATransform3DMakeScale(shown, shown, 1)
    transform.m41 = (1 - shown) * (point.x - center.x)
    transform.m42 = (1 - shown) * (point.y - center.y)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in [edgeLayer, nodeLayer] { layer.transform = transform }
    CATransaction.commit()
  }

  private func endStretch() {
    guard overshoot != nil else { return }
    overshoot = nil
    let parts = [edgeLayer, nodeLayer].map { layer -> MotionLedger.Part in
      let from = (layer.presentation() ?? layer).transform
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = CATransform3DIdentity
      CATransaction.commit()
      return .init(
        layer: layer, key: "rubberBack",
        animation: Motion.spring(
          .rubberBack, keyPath: "transform", from: NSValue(caTransform3D: from),
          to: NSValue(caTransform3D: CATransform3DIdentity)))
    }
    MotionLedger.shared.start(.rubberBack, target: "zoom", parts)
  }

  /// ⌘= and ⌘-: a step around the centre of the view.
  func zoom(by factor: Double) {
    setViewport(
      viewport.zoomed(
        by: factor, around: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds.size))
    settleRendering()
  }

  /// ⌘-scroll: `dy` of wheel travel (positive zooms in) around `point`. The picture does not
  /// stretch at a limit as a pinch does: a wheel has no end to spring back from.
  func zoomScroll(dy: Double, at point: CGPoint, idle: Duration = .milliseconds(250)) {
    holdGesture(idle: idle)
    setViewport(
      viewport.zoomed(by: Viewport.wheelFactor(dy), around: point, in: bounds.size))
    settleRendering()
  }

  func zoomToFit() {
    takeCamera()
    setViewport(
      Viewport.fitting(graph.nodes.map(\.frame), in: bounds.size, margin: Self.fitMargin))
    settleRendering()
  }

  override func scrollWheel(with event: NSEvent) {
    // A wheel mouse reports lines, a trackpad points.
    let precise = event.hasPreciseScrollingDeltas
    let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
    let idle = phased ? Self.phasedIdle : Duration.milliseconds(250)
    if event.modifierFlags.contains(.command) {
      zoomScroll(
        dy: event.scrollingDeltaY * (precise ? 1.0 : 40.0),
        at: convert(event.locationInWindow, from: nil), idle: idle)
    } else {
      let unit = precise ? 1.0 : 10.0
      scroll(dx: event.scrollingDeltaX * unit, dy: event.scrollingDeltaY * unit, idle: idle)
    }
    let over: NSEvent.Phase = [.ended, .cancelled]
    let momentumEnded = !event.momentumPhase.isDisjoint(with: over)
    let fingersLifted = event.momentumPhase.isEmpty && !event.phase.isDisjoint(with: over)
    if momentumEnded || fingersLifted { releaseGesture() }
  }

  override func magnify(with event: NSEvent) {
    let phased = !event.phase.isEmpty
    magnify(
      by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil),
      idle: phased ? Self.phasedIdle : .milliseconds(250))
    if !event.phase.isDisjoint(with: [.ended, .cancelled]) { releaseGesture() }
  }

  // MARK: Selection and keys

  func nodeId(at point: CGPoint) -> String? {
    let spot = viewport.canvas(point, in: bounds.size)
    let hits = graph.nodes.filter { $0.frame.contains(spot) }
    return hits.first { $0.id == selection }?.id ?? hits.last?.id
  }

  func move(_ direction: Direction) {
    let nodes = graph.nodes
    let next: String?
    if let current = selection {
      next = CanvasNavigation.nearest(from: current, toward: direction, in: nodes)
    } else {
      let center = viewport
      next =
        nodes.min {
          hypot($0.x - center.cx, $0.y - center.cy) < hypot($1.x - center.cx, $1.y - center.cy)
        }?.id
    }
    guard let next, let node = nodes.first(where: { $0.id == next }) else { return }
    selected = next
    setViewport(viewport.revealing(node.frame, in: bounds.size, margin: Self.revealMargin))
    refresh()
  }

  /// The overview's own keys: arrows move the selection and Return focuses it.
  func handleKey(_ event: NSEvent) -> Bool {
    guard !isHidden, event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return false }
    switch event.keyCode {
    case 123: move(.left)
    case 124: move(.right)
    case 125: move(.down)
    case 126: move(.up)
    case 36, 76:
      guard let id = selection else { return true }
      (NSApp as? BarestateApplication)?.consumeKeyUp(of: event.keyCode)
      app.focusNode(id)
    default: return false
    }
    return true
  }

  // MARK: Pointer

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(app.root)
    let point = convert(event.locationInWindow, from: nil)
    guard !zoomPill.frame.contains(point) else { return }
    guard let id = nodeId(at: point), let node = graph.nodes.first(where: { $0.id == id })
    else {
      pan = Pan(start: point, origin: viewport)
      return pointerMoved(to: point)
    }
    selected = id
    drag = Drag(
      id: id, start: point, origin: CGPoint(x: node.x, y: node.y), zoom: viewport.zoom)
    animateHold(id, .nodePress)
    refresh()
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard var held = drag else { return panned(to: point) }
    let (dx, dy) = (point.x - held.start.x, point.y - held.start.y)
    if !held.moved {
      guard hypot(dx, dy) >= Self.dragThreshold else { return }
      held.moved = true
      drag = held
      takeCamera()
      holdGesture()
      animateHold(held.id, .nodePickup)
      pointerMoved(to: point)
    }
    let target = CanvasPoint(x: held.origin.x + dx / held.zoom, y: held.origin.y + dy / held.zoom)
    app.canvas.edit { $0.move(node: held.id, to: target) }
  }

  /// The camera follows a press on empty canvas. A press that has not left the click radius
  /// pans nothing, and once it has, the pan is measured from where the press began.
  private func panned(to point: CGPoint) {
    guard var held = pan else { return }
    let delta = CGSize(width: point.x - held.start.x, height: point.y - held.start.y)
    if !held.moved {
      guard hypot(delta.width, delta.height) >= Self.dragThreshold else { return }
      held.moved = true
      pan = held
      takeCamera()
    }
    holdGesture()
    setViewport(held.origin.panned(byScreen: delta))
  }

  override func mouseUp(with event: NSEvent) {
    if let held = pan {
      pan = nil
      if held.moved { releaseGesture() }
      return pointerMoved(to: convert(event.locationInWindow, from: nil))
    }
    guard let held = drag else { return }
    drag = nil
    animateHold(held.id, held.moved ? .nodeDrop : .nodePress)
    if held.moved {
      releaseGesture()
      refresh()
      pointerMoved(to: convert(event.locationInWindow, from: nil))
    } else {
      app.cardClick = (held.id, event.locationInWindow)
      app.focusNode(held.id)
    }
  }

  // MARK: Title

  func controlTextDidEndEditing(_ notification: Notification) {
    let text = titleField.stringValue
    if !reverting {
      app.canvas.edit {
        let before = $0.title
        $0.setTitle(text)
        return $0.title != before
      }
    }
    reverting = false
    titleField.stringValue = graph.title
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      window?.makeFirstResponder(app.root)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      reverting = true
      window?.makeFirstResponder(app.root)
      return true
    default:
      return false
    }
  }

  // MARK: Accessibility

  /// The cards are layers, so each page node gets an accessibility element of its own.
  private var nodeElements: [String: NodeAccessibilityElement] = [:]

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .group }
  override func accessibilityLabel() -> String? { graph.title }

  override func accessibilityChildren() -> [Any]? {
    let current = app.activeNodeId
    let chosen = selection
    var live = Set<String>()
    var elements: [Any] = [titleField]
    if !legend.isHidden { elements.append(legend) }
    elements.append(zoomPill)
    for node in graph.nodes {
      live.insert(node.id)
      let element = nodeElements[node.id] ?? NodeAccessibilityElement()
      nodeElements[node.id] = element
      let host = PageCaption.make(url: node.url, title: node.title, ssl: .unknown)?.host ?? node.url
      var parts = [node.title.isEmpty ? host : node.title, host]
      parts.append(node.isArchived ? "closed page" : "live page")
      if node.id == current { parts.append("Current page") }
      if let status = museStatus(of: node) { parts.append(status) }
      element.setAccessibilityRole(.button)
      element.setAccessibilityEnabled(true)
      element.setAccessibilityParent(self)
      element.setAccessibilityLabel(parts.joined(separator: ", "))
      element.selectedNode = node.id == chosen
      element.onPress = { [weak self] in self?.app.focusNode(node.id) }
      let size = CGSize(
        width: PageGraph.nodeWidth * viewport.zoom, height: PageGraph.nodeHeight * viewport.zoom)
      let centre = viewport.screen(CGPoint(x: node.x, y: node.y), in: bounds.size)
      let local = CGRect(
        x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width,
        height: size.height)
      if let window {
        element.setAccessibilityFrame(window.convertToScreen(convert(local, to: nil)))
      }
      elements.append(element)
      if node.id == hovered { elements.append(openChipElement(for: node, in: local)) }
    }
    nodeElements = nodeElements.filter { live.contains($0.key) }
    return elements
  }

  /// The "Open" chip that shows on the hovered card, as a button of its own.
  private let chipElement = NodeAccessibilityElement()

  private func openChipElement(for node: PageNode, in card: CGRect) -> NodeAccessibilityElement {
    chipElement.setAccessibilityRole(.button)
    chipElement.setAccessibilityEnabled(true)
    chipElement.setAccessibilityParent(self)
    chipElement.setAccessibilityLabel("Open")
    chipElement.setAccessibilityHelp(node.title)
    chipElement.onPress = { [weak self] in self?.app.focusNode(node.id) }
    if let window {
      chipElement.setAccessibilityFrame(
        window.convertToScreen(convert(Self.chipRect(in: card), to: nil)))
    }
    return chipElement
  }

  /// The chip of a card drawn at `card`, scaled with it.
  static func chipRect(in card: CGRect) -> CGRect {
    let scale = card.width / PageGraph.nodeWidth
    let chip = NodeCard.chipFrame
    return CGRect(
      x: card.minX + chip.minX * scale, y: card.minY + chip.minY * scale,
      width: chip.width * scale, height: chip.height * scale)
  }

  private func museStatus(of node: PageNode) -> String? {
    app.runs.runs(ownedBy: node.tabId).last?.museLabel
  }

  // MARK: Test state

  /// The card of `id` as it is on screen, in this view's coordinates; nil when it is not drawn.
  func cardRect(_ id: String) -> NSRect? {
    guard let card = cards[id], let layer, !card.layer.isHidden else { return nil }
    return layer.convert(card.cardLayer.bounds, from: card.cardLayer)
  }

  /// Where the card will be once the overview shows, in the window's coordinates (the canvas fills it).
  func overviewCardRect(of id: String) -> CGRect? { cardRect(id) }

  /// A view standing where a card is, so the hooks can click and drag it like any control.
  func probe(for id: String) -> NSView? {
    guard let rect = cardRect(id) else { return nil }
    probeView.frame = rect
    if probeView.superview == nil { addSubview(probeView) }
    return probeView
  }

  private let probeView = ProbeView()
  var zoomLevel: Double { viewport.zoom }
  /// How far a pinch past a zoom limit currently stretches the picture; 1 when it does not.
  var stretchScale: Double { Double((nodeLayer.presentation() ?? nodeLayer).transform.m11) }
}

final class NodeAccessibilityElement: NSAccessibilityElement {
  var selectedNode = false
  var onPress: (() -> Void)?

  override func isAccessibilitySelected() -> Bool { selectedNode }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}

final class ProbeView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NodeCard.Look {
  init(
    _ node: PageNode, state: PreviewState, hasImage: Bool, current: Bool, selected: Bool,
    scale: CGFloat, runs: [Run] = []
  ) {
    let host = PageCaption.make(url: node.url, title: node.title, ssl: .unknown)?.host ?? node.url
    self.init(
      title: node.title.isEmpty ? host : node.title,
      subtitle: node.isArchived ? "Closed page · Reopen" : "Live page · \(host)", origin: host,
      preview: state, hasImage: hasImage, current: current, selected: selected, scale: scale,
      muse: runs.last?.museLabel ?? "", museState: runs.last?.state, runs: runs.map(\.id))
  }
}
