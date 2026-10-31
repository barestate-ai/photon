import AppKit
import BarestateCore

@MainActor
extension AppController {
  /// `test.ui.canvas`: the page graph as stored. Node x and y are slot centres in canvas
  /// coordinates, w and h the card plus caption.
  func canvasState() -> JSON {
    let graph = canvas.graph
    let nodes = graph.nodes.map { node -> JSON in
      [
        "id": .string(node.id), "kind": .string(node.isArchived ? "archived" : "live"),
        "tabId": node.tabId.map { .string($0) } ?? .null, "url": .string(node.url),
        "title": .string(node.title), "x": .number(node.x), "y": .number(node.y),
        "w": .number(PageGraph.nodeWidth), "h": .number(PageGraph.nodeHeight),
        "previewState": .string(canvas.previews.state(of: node.id).rawValue),
        "documentKey": canvas.previews.documentKey(of: node.id).map { .string($0) } ?? .null,
      ]
    }
    let edges = graph.edges.map { edge -> JSON in
      [
        "from": .string(edge.from), "to": .string(edge.to), "kind": .string(edge.kind.rawValue),
        "runId": edge.runId.map { .string($0) } ?? .null,
      ]
    }
    return [
      "title": .string(graph.title),
      "viewport": [
        "cx": .number(graph.viewport.cx), "cy": .number(graph.viewport.cy),
        "zoom": .number(graph.viewport.zoom),
      ],
      "nodes": .array(nodes), "edges": .array(edges),
    ]
  }
}

private func hexString(_ color: CGColor?) -> String {
  guard let color = NSColor(cgColor: color ?? CGColor(gray: 0, alpha: 0))?.usingColorSpace(.sRGB)
  else { return "" }
  return String(
    format: "%02x%02x%02x", Int((color.redComponent * 255).rounded()),
    Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
}

extension AppController {
  /// `test.ui.overview`: what the overview draws, read back from its layers and views. Frames are
  /// window points from the top left.
  func overviewState() -> JSON {
    guard let view = root?.canvasView, let window else { return .null }
    func frame(_ rect: NSRect) -> JSON {
      var rect = view.convert(rect, to: nil)
      rect.origin.y = window.frame.height - rect.maxY
      return json(rect)
    }
    let current = activeNodeId
    let nodes = canvas.graph.nodes.compactMap { node -> JSON? in
      guard let card = view.cards[node.id], let rect = view.cardRect(node.id) else { return nil }
      let look = card.look
      return [
        "id": .string(node.id), "frame": frame(rect), "title": .string(look.title),
        "subtitle": .string(look.subtitle), "origin": .string(look.origin),
        "selected": .bool(look.selected), "current": .bool(look.current),
        "hasImage": .bool(look.hasImage), "placeholder": .bool(!look.hasImage),
        "dimmed": .bool(look.hasImage && look.preview == .stale),
        "note": .string(look.hasImage && look.preview == .stale ? "Preview from earlier" : ""),
        "muse": .string(look.muse), "runs": .array(look.runs.map { .string($0) }),
      ]
    }
    let zoom = view.zoomLevel
    let edges = view.trails.keys.sorted().compactMap { key -> JSON? in
      guard let line = view.trails[key] else { return nil }
      let parts = key.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
      return [
        "from": .string(parts[0]), "to": .string(parts[1]), "kind": .string(parts[2]),
        "color": .string(hexString(line.strokeColor)),
        "width": .number((line.lineWidth / zoom * 1e4).rounded() / 1e4),
        "dash": .array(
          (line.lineDashPattern ?? []).map {
            .number(($0.doubleValue / zoom * 1e4).rounded() / 1e4)
          }),
        "cap": .string(line.lineCap == .round ? "round" : "other"),
        "dashPhase": .number(((line.presentation() ?? line).lineDashPhase * 1e3).rounded() / 1e3),
      ]
    }
    let titleFrame = frame(view.titleField.frame)
    let legend = view.legend
    var label: JSON = .null
    if let id = current, let rect = view.cardRect(id) {
      label = ["text": "Current page", "node": .string(id), "frame": frame(rect)]
    }
    return [
      "visible": .bool(!view.isHiddenOrHasHiddenAncestor),
      "size": ["w": .number(view.bounds.width), "h": .number(view.bounds.height)],
      "selection": view.selection.map { .string($0) } ?? .null,
      "title": [
        "text": .string(view.titleField.stringValue), "frame": titleFrame,
        "editing": .bool(view.titleField.currentEditor() != nil),
        "font": .string(view.titleField.font?.fontName ?? ""),
      ],
      "legend": [
        "visible": .bool(!legend.isHidden), "frame": frame(legend.frame),
        "items": .array(
          legend.items.map {
            ["label": .string($0.label), "color": .string($0 == .muse ? "b66a48" : "c0c4b9")]
          }),
      ],
      "nodes": .array(nodes), "edges": .array(edges), "currentLabel": label,
      "notice": [
        "text": .string(root?.noticeText ?? ""), "visible": .bool(root?.noticeText != nil),
      ],
    ]
  }
}

extension AppController {
  /// `test.ui.focus`: the focused page in its context. Frames are window points from the top left;
  /// `liveFrame` is the active page's own view, which must equal `card`.
  func focusState() -> JSON {
    guard let root else { return .null }
    let view = root.focusContext!
    let layout = root.focusLayout
    func column(_ nodes: [PageNode]) -> JSON {
      .array(
        nodes.compactMap { node -> JSON? in
          guard let rect = view.cardRect(node.id) else { return nil }
          let look = view.look(node.id)
          return [
            "id": .string(node.id), "frame": json(rect), "title": .string(look?.title ?? ""),
            "subtitle": .string(look?.subtitle ?? ""), "hasImage": .bool(look?.hasImage ?? false),
          ]
        })
    }
    func frame(_ rect: CGRect?) -> JSON { rect.map(json) ?? .null }
    return [
      "visible": .bool(!view.isHidden),
      "size": ["w": .number(root.bounds.width), "h": .number(root.bounds.height)],
      "columns": .bool(layout.columns), "card": json(layout.card),
      "liveFrame": activeTab.map { windowRect($0.view) } ?? .null,
      "caption": json(layout.caption),
      "currentLabel": ["text": "Current page", "frame": json(view.currentLabelFrame)],
      "museLabel": [
        "text": .string(view.museLabel), "frame": frame(view.museLabelFrame),
      ],
      "trails": .array(
        view.trails.keys.sorted().compactMap { key -> JSON? in
          guard let (route, line) = view.trails[key] else { return nil }
          let parts = key.split(separator: ">").map(String.init)
          func point(_ p: CGPoint) -> JSON { ["x": .number(p.x), "y": .number(p.y)] }
          return [
            "node": .string(parts[0]), "kind": .string(parts[1]),
            "color": .string(hexString(line.strokeColor)),
            "width": .number(line.lineWidth),
            "dash": .array((line.lineDashPattern ?? []).map { .number($0.doubleValue) }),
            "cap": .string(line.lineCap == .round ? "round" : "other"),
            "start": point(route.start), "control": point(route.control), "end": point(route.end),
          ]
        }),
      "left": column(root.context.left),
      "right": column(root.context.right),
      "neighbours": .array((root.context.left + root.context.right).map { .string($0.id) }),
    ]
  }
}

/// Stand-ins for the pointer gestures that move a node, pan and zoom the camera and edit the
/// title: they reach the same graph writes. `gesture: true` / `false` brackets a held gesture.
@MainActor
func registerCanvasHooks(_ dispatcher: RPCDispatcher, controller: AppController) {
  dispatcher.register("test.canvas") { params in
    let gesture = params["gesture"]?.bool
    if gesture == true { controller.canvas.gesture(true) }
    if let move = params["move"] {
      guard let id = move["node"]?.string, let x = move["x"]?.number, let y = move["y"]?.number,
        controller.canvas.graph.nodes.contains(where: { $0.id == id })
      else { throw RPCError.invalidParams("move needs node (an existing node id), x and y") }
      controller.root?.canvasView?.takeCamera()
      controller.canvas.edit { $0.move(node: id, to: CanvasPoint(x: x, y: y)) }
    }
    if let view = params["viewport"] {
      controller.root?.canvasView?.takeCamera()
      let current = controller.canvas.graph.viewport
      let next = Viewport(
        cx: view["cx"]?.number ?? current.cx, cy: view["cy"]?.number ?? current.cy,
        zoom: view["zoom"]?.number ?? current.zoom)
      controller.canvas.edit {
        $0.viewport = next
        return next != current
      }
    }
    if let title = params["title"]?.string {
      controller.canvas.edit {
        let before = $0.title
        $0.setTitle(title)
        return $0.title != before
      }
    }
    if gesture == false { controller.canvas.gesture(false) }
    return controller.canvasState()
  }
}

/// The scroll and pinch a trackpad sends the overview, without a trackpad: they call the handlers
/// the real events call. `at` is in window points from the top left.
@MainActor
func registerPointerHooks(_ dispatcher: RPCDispatcher, controller: AppController) {
  let probe = FrameProbe()
  func view() throws -> CanvasView {
    guard let view = controller.root?.canvasView, !view.isHidden else {
      throw RPCError.failure("the overview is not showing")
    }
    return view
  }

  dispatcher.register("test.scroll") { params in
    guard let dx = params["dx"]?.number, let dy = params["dy"]?.number else {
      throw RPCError.invalidParams("dx and dy (numbers) required")
    }
    // The launcher covers the canvas, so a real scroll never reaches it.
    let canvas = try view()
    if !controller.launcher.isOpen { canvas.scroll(dx: dx, dy: dy) }
    return controller.canvasState()
  }

  // `pan` {dx, dy} scrolls the overview by that much on every display-link tick, back and forth
  // every 30 ticks, as a trackpad would, without a socket round trip per step. `stop` returns
  // `intervalsMs` between the commits of consecutive pan steps (between ticks when nothing
  // panned), the raw `tickIntervalsMs`, and `steps`, `commits` and `notPresented` counts.
  dispatcher.register("test.frameProbe") { params in
    switch params["action"]?.string {
    case "start":
      guard let root = controller.root else { throw RPCError.failure("no window") }
      let pan = try params["pan"].map { _ in
        (
          dx: params["pan"]?["dx"]?.number ?? 0, dy: params["pan"]?["dy"]?.number ?? 0,
          canvas: try view()
        )
      }
      probe.start(on: root, pan: pan)
      return ["running": .bool(true)]
    case "stop":
      let result = probe.stop()
      // With a pan the intervals are between committed canvas updates; without one, between ticks.
      let intervals = result.steps > 0 ? result.commitsMs : result.ticksMs
      return [
        "intervalsMs": .array(intervals.map { .number($0) }),
        "tickIntervalsMs": .array(result.ticksMs.map { .number($0) }),
        "steps": .number(Double(result.steps)),
        "commits": .number(Double(result.commits)),
        "notPresented": .number(Double(result.notPresented)),
        "refreshHz": .number(Double(controller.window?.screen?.maximumFramesPerSecond ?? 0)),
      ]
    default:
      throw RPCError.invalidParams("action must be start or stop")
    }
  }

  // `by` is NSEvent.magnification: 0.1 zooms in by 10 %, -0.1 out by 10 %. In the focused page a
  // negative value leaves for the overview, as the pinch does.
  dispatcher.register("test.magnify") { params in
    guard let by = params["by"]?.number else {
      throw RPCError.invalidParams("by (number) required")
    }
    if controller.presentation == .focused {
      if by < 0, !controller.launcher.isOpen { controller.perform(.showOverview) }
      return controller.canvasState()
    }
    let canvas = try view()
    guard !controller.launcher.isOpen else { return controller.canvasState() }
    let point = CGPoint(
      x: params["at"]?["x"]?.number ?? canvas.bounds.midX,
      y: params["at"]?["y"]?.number ?? canvas.bounds.midY)
    canvas.magnify(by: 1 + by, at: point)
    return controller.canvasState()
  }
}

/// Preview cache state and the knobs that make stale-capture races deterministic.
@MainActor
func registerPreviewHooks(_ dispatcher: RPCDispatcher, controller: AppController) {
  let previews = controller.previews

  dispatcher.register("test.previews") { params in
    if let limits = params["limits"] {
      guard let count = limits["count"]?.int, let bytes = limits["bytes"]?.int, count >= 0,
        bytes >= 0
      else { throw RPCError.invalidParams("limits needs count and bytes (non-negative integers)") }
      controller.canvas.previews.limits = .init(count: count, bytes: bytes)
    }
    if params["reset"]?.bool == true {
      controller.canvas.previews.limits = PreviewCache.defaultLimits
    }
    if let auto = params["auto"]?.bool { previews.autoCapture = auto }
    return previews.state()
  }

  dispatcher.register("test.previewHold") { params in
    previews.holdNext = params["on"]?.bool ?? true
    return ["holdNext": .bool(previews.holdNext)]
  }

  dispatcher.register("test.previewRelease") { _ in
    previews.release()
    return previews.state()
  }

  // Captures the tab as the presentation would. With a hold set it returns once the screenshot
  // is taken and held (outcome "held"); otherwise when the capture has been decided.
  dispatcher.register("test.previewCapture") { params in
    let tab = try controller.resolveTab(params)
    let (width, height) = (params["width"]?.int ?? 440, params["height"]?.int ?? 300)
    guard width > 0, height > 0 else {
      throw RPCError.invalidParams("width and height must be positive")
    }
    let capture = Task { await previews.capture(tab, cardWidth: width, cardHeight: height) }
    if previews.holdNext {
      await previews.waitUntilHeldOrDone()
      if previews.isHeld { return ["outcome": "held"] }
    }
    return ["outcome": .string(await capture.value.rawValue)]
  }
}

/// Runs on the display link. With a pan, every tick scrolls the overview inside its own
/// transaction and records when that transaction committed, so the intervals between consecutive
/// committed canvas updates are what a late main thread stretches. After each commit the next tick
/// checks that the card's presentation layer shows the position that step committed.
@MainActor
final class FrameProbe: NSObject {
  struct Result {
    var ticksMs: [Double] = []
    var commitsMs: [Double] = []
    var commits = 0
    var steps = 0
    var notPresented = 0
  }

  private var link: CADisplayLink?
  private var last: CFTimeInterval?
  private var lastCommit: CFTimeInterval?
  private var result = Result()
  private var pan: (dx: Double, dy: Double, canvas: CanvasView)?
  private var expected: (layer: CALayer, position: CGPoint)?

  func start(on view: NSView, pan: (dx: Double, dy: Double, canvas: CanvasView)? = nil) {
    link?.invalidate()
    result = Result()
    (last, lastCommit, expected) = (nil, nil, nil)
    self.pan = pan
    link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link?.add(to: .main, forMode: .common)
  }

  @objc private func tick(_ link: CADisplayLink) {
    if let last { result.ticksMs.append((link.timestamp - last) * 1000) }
    last = link.timestamp
    guard let pan else { return }
    if let (layer, position) = expected, layer.presentation()?.position != position {
      result.notPresented += 1
    }
    result.steps += 1
    let direction: Double = (result.steps / 30) % 2 == 0 ? 1 : -1
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated { self?.committed(at: CACurrentMediaTime()) }
    }
    pan.canvas.scroll(dx: pan.dx * direction, dy: pan.dy * direction)
    CATransaction.commit()
    expected = pan.canvas.cards.values.first { !$0.layer.isHidden }
      .map { ($0.layer, $0.layer.position) }
  }

  private func committed(at time: CFTimeInterval) {
    if let lastCommit { result.commitsMs.append((time - lastCommit) * 1000) }
    lastCommit = time
    result.commits += 1
  }

  func stop() -> Result {
    link?.invalidate()
    link = nil
    return result
  }
}
