import AppKit
import BarestateCore

/// Around the focused page (frame 777:642): a petrol ring just outside the live page, the
/// "Current page" and Muse status labels above it, and the pages it is connected to in two
/// columns, joined to it by the same dotted trails as the overview. It draws only outside the
/// page's rect and answers hits only on a column card, so the page keeps every click and key it
/// is given.
@MainActor
final class FocusContextView: NSView {
  unowned let app: AppController
  private let ring = CALayer()
  private let trailLayer = CALayer()
  private let trailMask = CAShapeLayer()
  private let currentDot = CALayer()
  private let currentText = CATextLayer()
  private let museDot = CALayer()
  private let museText = CATextLayer()
  private var mark: MuseMark!
  private var cards: [String: NodeCard] = [:]
  private let probeView = ProbeView()
  /// The column cards on show, with the rect each answers hits in (the card and its caption).
  private(set) var slots: [(id: String, rect: CGRect)] = []
  private(set) var museLabel = ""
  /// One per recorded connection between a column card and the focused page.
  private(set) var trails: [String: (route: EdgeRoute, line: CAShapeLayer)] = [:]
  private var pressed: String?

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(app: AppController) {
    self.app = app
    super.init(frame: .zero)
    wantsLayer = true
    isHidden = true
    ring.borderWidth = 1.5
    ring.borderColor = Design.petrol.cgColor
    ring.cornerRadius = 3
    currentDot.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
    currentDot.cornerRadius = 3
    currentDot.backgroundColor = Design.accent.cgColor
    museDot.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
    museDot.cornerRadius = 3
    museDot.backgroundColor = Design.copper.cgColor
    for text in [currentText, museText] {
      text.truncationMode = .end
      text.isWrapped = false
    }
    currentText.string = NodeCard.attributed(
      "Current page", Fonts.manrope(12, weight: 500), Design.petrol)
    trailMask.fillRule = .evenOdd
    trailLayer.mask = trailMask
    for part in [trailLayer, ring, currentDot, currentText, museDot, museText] {
      layer?.addSublayer(part)
    }
    setAccessibilityElement(false)
    mark = MuseMark(surface: "focus", host: layer!, dot: museDot, label: museText)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Only a column card is hit; the rest of the window, page included, is not this view's.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, slots.contains(where: { $0.rect.contains(convert(point, from: superview)) })
    else { return nil }
    return self
  }

  private func slot(at point: CGPoint) -> String? {
    slots.first { $0.rect.contains(point) }?.id
  }

  override func mouseDown(with event: NSEvent) {
    pressed = slot(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    defer { pressed = nil }
    guard let pressed, slot(at: convert(event.locationInWindow, from: nil)) == pressed else {
      return
    }
    app.focusNode(pressed)
  }

  // MARK: Drawing

  func refresh() {
    guard let root = app.root else { return }
    let focused = app.presentation == .focused && app.activeTab != nil
    let wasShown = !isHidden
    isHidden = !focused
    guard focused else { return mark.hide() }
    let layout = root.focusLayout
    let scale = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    ring.frame = layout.card.insetBy(dx: -1.5, dy: -1.5)
    placeLabels(layout.card, scale: scale, animated: wasShown)
    let left = zip(root.context.left, layout.left)
    let right = zip(root.context.right, layout.right)
    var live = Set<String>()
    slots = []
    for (node, rect) in Array(left) + Array(right) {
      live.insert(node.id)
      show(node, in: rect, scale: scale)
    }
    for id in cards.keys where !live.contains(id) {
      cards.removeValue(forKey: id)?.layer.removeFromSuperlayer()
    }
    drawTrails(layout)
  }

  /// A curve from each column card to the page's near edge, level with the card it leaves. The
  /// mask cuts the live page's rect out of the layer, so nothing can ever draw over the page.
  private func drawTrails(_ layout: FocusLayout) {
    trailLayer.frame = bounds
    trailMask.frame = bounds
    let hole = CGMutablePath()
    hole.addRect(bounds)
    hole.addRect(layout.card)
    trailMask.path = hole
    var live = Set<String>()
    let focus = app.activeNodeId
    let edges = app.canvas.graph.edges
    for (id, rect) in slots {
      let card = cardRect(id) ?? rect
      let kinds = Set(
        edges.filter { ($0.from == focus && $0.to == id) || ($0.to == focus && $0.from == id) }
          .map(\.kind))
      let level = min(max(card.midY, layout.card.minY + 16), layout.card.maxY - 16)
      let target = CGRect(
        x: layout.card.minX - 4, y: level, width: layout.card.width + 8, height: 0)
      for (index, kind) in kinds.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
        let key = "\(id)>\(kind.rawValue)"
        live.insert(key)
        let route = EdgeRoute.make(
          from: card, to: target, bow: index == 0 ? Trail.bow : -Trail.bow, sideways: true)
        let line = trails[key]?.line ?? Trail.makeLayer()
        if line.superlayer == nil { trailLayer.addSublayer(line) }
        line.path = Trail.path(route)
        Trail.style(line, kind: kind)
        trails[key] = (route, line)
      }
    }
    for key in trails.keys where !live.contains(key) {
      trails.removeValue(forKey: key)?.line.removeFromSuperlayer()
    }
  }

  private func show(_ node: PageNode, in rect: CGRect, scale: CGFloat) {
    let factor = rect.width / PageGraph.nodeWidth
    let card = cards[node.id] ?? makeCard(node.id)
    card.layer.position = CGPoint(x: rect.midX, y: rect.midY)
    card.layer.setAffineTransform(CGAffineTransform(scaleX: factor, y: factor))
    let state = app.canvas.previews.state(of: node.id)
    let image = state == .none ? nil : app.canvas.previews.preview(for: node.id)?.image
    card.apply(
      NodeCard.Look(
        node, state: state, hasImage: image != nil, current: false, selected: false,
        scale: scale * max(1, ceil(factor * 2) / 2)),
      newImage: image.flatMap { card.isShowing($0) ? nil : $0 })
    slots.append((node.id, rect))
  }

  private func makeCard(_ id: String) -> NodeCard {
    let card = NodeCard(id: id)
    layer?.addSublayer(card.layer)
    cards[id] = card
    return card
  }

  /// The labels sit just above the card: "Current page" at its left edge, and the Muse status,
  /// when a task owns this page, 342 pt in from it (screen-4), or against its right edge where
  /// the card is narrower.
  private func placeLabels(_ card: CGRect, scale: CGFloat, animated: Bool) {
    let top = card.minY - 28
    currentDot.frame.origin = CGPoint(x: card.minX, y: top + 6)
    currentText.contentsScale = scale
    currentText.frame = CGRect(x: card.minX + 14, y: top, width: 120, height: 18)
    let run = app.runs.runs(ownedBy: app.activeTabId).last
    museLabel = run?.museLabel ?? ""
    mark.show(
      run?.state, run: run?.id ?? "", node: app.activeNodeId ?? "", text: museLabel,
      ring: card.insetBy(dx: -4, dy: -4), animated: animated)
    let shown = !museLabel.isEmpty
    museDot.isHidden = !shown
    museText.isHidden = !shown
    guard shown else { return }
    let text = NodeCard.attributed(museLabel, Fonts.manrope(13), Design.ink)
    let width = ceil(text.size().width) + 2
    museText.string = text
    museText.contentsScale = scale
    let dotX = min(card.minX + 342, card.maxX - width - 14)
    museText.frame = CGRect(x: dotX + 14, y: top - 1, width: width, height: 20)
    museDot.frame.origin = CGPoint(x: dotX, y: top + 6)
  }

  // MARK: Test state

  var currentLabelFrame: CGRect { currentText.frame }
  var museLabelFrame: CGRect? { museText.isHidden ? nil : museText.frame }

  func cardRect(_ id: String) -> CGRect? {
    guard let rect = slots.first(where: { $0.id == id })?.rect else { return nil }
    return CGRect(
      x: rect.minX, y: rect.minY, width: rect.width,
      height: rect.width * PageNode.cardHeight / PageGraph.nodeWidth)
  }

  func look(_ id: String) -> NodeCard.Look? { cards[id]?.look }

  func probe(for id: String) -> NSView? {
    guard let rect = cardRect(id), !isHidden else { return nil }
    probeView.frame = rect
    if probeView.superview == nil { addSubview(probeView) }
    return probeView
  }
}
