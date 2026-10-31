import AppKit
import BarestateCore

/// One page of the overview as plain layers: a bordered card holding the page's preview (or its
/// title and origin when there is none), the caption below it, and the "Current page" label and
/// selection ring around it. The card never draws page content of its own.
@MainActor
final class NodeCard {
  struct Look: Equatable {
    var title = ""
    var subtitle = ""
    var origin = ""
    var preview = PreviewState.none
    var hasImage = false
    var current = false
    var selected = false
    var scale: CGFloat = 0
    /// "Muse · <status>" of the newest task that owns this page; empty when none does.
    var muse = ""
    var museState: RunState?
    /// Every task that owns this page, oldest first.
    var runs: [String] = []
  }

  static let captionTop = PageNode.cardHeight + 4

  let id: String
  let layer = CALayer()
  private var hovering = false
  private let card = CALayer()
  var cardLayer: CALayer { card }
  private let image = CALayer()
  private let placeholderTitle = CATextLayer()
  private let placeholderOrigin = CATextLayer()
  private let staleNote = CATextLayer()
  private let title = CATextLayer()
  private let subtitle = CATextLayer()
  private let ring = CALayer()
  private let dot = CALayer()
  private let currentLabel = CATextLayer()
  private let museDot = CALayer()
  private let museLabel = CATextLayer()
  private var mark: MuseMark!
  private(set) var look = Look()
  /// The image on show, so an unchanged preview is not assigned again.
  private var shown: CGImage?

  init(id: String) {
    self.id = id
    layer.bounds = CGRect(x: 0, y: 0, width: PageGraph.nodeWidth, height: PageGraph.nodeHeight)
    card.frame = CGRect(x: 0, y: 0, width: PageGraph.nodeWidth, height: PageNode.cardHeight)
    card.backgroundColor = Design.surface.cgColor
    card.cornerRadius = Design.radiusControl
    card.shadowColor = NSColor.black.cgColor
    card.shadowOffset = CGSize(width: 0, height: 2)
    card.shadowRadius = 8
    card.shadowOpacity = 0
    image.frame = card.bounds
    image.cornerRadius = Design.radiusControl
    image.masksToBounds = true
    image.contentsGravity = .resizeAspectFill
    image.isHidden = true
    for text in [
      placeholderTitle, placeholderOrigin, staleNote, title, subtitle, currentLabel, museLabel,
    ] {
      text.isWrapped = false
      text.truncationMode = .end
    }
    placeholderTitle.isWrapped = true
    placeholderTitle.alignmentMode = .center
    placeholderTitle.frame = CGRect(x: 16, y: 56, width: 188, height: 44)
    placeholderOrigin.alignmentMode = .center
    placeholderOrigin.frame = CGRect(x: 16, y: 108, width: 188, height: 18)
    staleNote.alignmentMode = .center
    staleNote.backgroundColor = Design.surface.withAlphaComponent(0.92).cgColor
    staleNote.cornerRadius = 4
    staleNote.frame = CGRect(x: 8, y: PageNode.cardHeight - 26, width: 204, height: 18)
    title.frame = CGRect(x: 0, y: Self.captionTop, width: PageGraph.nodeWidth, height: 20)
    subtitle.frame = CGRect(x: 0, y: Self.captionTop + 24, width: PageGraph.nodeWidth, height: 18)
    ring.frame = card.bounds.insetBy(dx: -3, dy: -3)
    ring.cornerRadius = 9
    ring.borderWidth = 1.5
    ring.borderColor = Design.petrol.cgColor
    ring.isHidden = true
    dot.frame = CGRect(x: 0, y: -23, width: 6, height: 6)
    dot.cornerRadius = 3
    dot.backgroundColor = Design.accent.cgColor
    currentLabel.frame = CGRect(x: 14, y: -29, width: 160, height: 18)
    museDot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
    museDot.cornerRadius = 3
    museDot.backgroundColor = Design.copper.cgColor
    for part in [dot, currentLabel, museDot, museLabel] { part.isHidden = true }
    for sublayer in [card, ring, title, subtitle, dot, currentLabel, museDot, museLabel] {
      layer.addSublayer(sublayer)
    }
    for sublayer in [image, placeholderTitle, placeholderOrigin, staleNote] {
      card.addSublayer(sublayer)
    }
    currentLabel.string = Self.attributed(
      "Current page", Fonts.manrope(12, weight: 500), Design.petrol)
    mark = MuseMark(surface: "overview", host: layer, dot: museDot, label: museLabel)
  }

  func isShowing(_ preview: CGImage) -> Bool { shown === preview }

  /// The overview is not showing this card: its Muse pulse stops with it.
  func hideMuse() { mark.hide() }

  /// A card off screen keeps no bitmap, so the preview cache's limits are the real bound.
  func dropImage() {
    hideMuse()
    guard shown != nil else { return }
    image.contents = nil
    shown = nil
    look = Look()
  }

  /// `newImage` is the node's preview when it is not the image already on show; the look says
  /// whether any image should be there at all.
  func apply(_ next: Look, newImage: CGImage?, animated: Bool = false) {
    if next.scale != look.scale {
      for text in [
        placeholderTitle, placeholderOrigin, staleNote, title, subtitle, currentLabel, museLabel,
      ] {
        text.contentsScale = next.scale
      }
      image.contentsScale = next.scale
    }
    var arriving = false
    if let newImage {
      if animated, shown != nil {
        crossfade()
      } else {
        // `look` is empty until the card is first drawn and again after `dropImage`, so a card
        // that comes back from a pan gets its image without a fade.
        arriving = animated && look.scale != 0 && !look.hasImage
      }
      image.contents = newImage
      shown = newImage
    } else if !next.hasImage {
      image.contents = nil
      shown = nil
    }
    mark.show(
      next.museState, run: next.runs.last ?? "", node: id, text: next.muse,
      ring: card.frame.insetBy(dx: -3, dy: -3), animated: animated)
    guard next != look else { return }
    look = next

    card.borderWidth = next.current ? 1.5 : 1
    card.borderColor = borderColor(current: next.current)
    let opacity = next.preview == .stale ? Motion.staleOpacity : 1
    if animated, !image.isHidden, next.hasImage, image.opacity != opacity { dim(to: opacity) }
    image.isHidden = !next.hasImage
    image.opacity = opacity
    placeholderTitle.isHidden = next.hasImage
    placeholderOrigin.isHidden = next.hasImage
    if arriving { fadeInFirstPreview(to: opacity) }
    placeholderTitle.string = Self.attributed(
      next.title, Fonts.manrope(14, weight: 500), Design.ink, align: .center)
    placeholderOrigin.string = Self.attributed(
      next.origin, Fonts.manrope(12), Design.muted, align: .center)
    staleNote.isHidden = !(next.hasImage && next.preview == .stale)
    staleNote.string = Self.attributed(
      "Preview from earlier", Fonts.manrope(11), Design.muted, align: .center)
    title.string = Self.attributed(
      next.title, Fonts.manrope(14, weight: 500), next.selected ? Design.petrol : Design.ink)
    subtitle.string = Self.attributed(next.subtitle, Fonts.manrope(12), Design.muted)
    ring.isHidden = !next.selected
    dot.isHidden = !next.current
    currentLabel.isHidden = !next.current
    placeMuse(next.muse, current: next.current)
  }

  /// The Muse label shares the "Current page" row's left edge and sits one row above it when
  /// both show.
  private func placeMuse(_ text: String, current: Bool) {
    museDot.isHidden = text.isEmpty
    museLabel.isHidden = text.isEmpty
    guard !text.isEmpty else { return }
    let top: CGFloat = current ? -49 : -29
    museLabel.frame = CGRect(x: 14, y: top, width: PageGraph.nodeWidth - 14, height: 18)
    museDot.position = CGPoint(x: 3, y: top + 12)
    museLabel.string = Self.attributed(text, Fonts.manrope(12, weight: 500), Design.ink)
  }

  private func borderColor(current: Bool) -> CGColor {
    (current ? Design.petrol : hovering ? Design.lineStrong : Design.line).cgColor
  }

  func setHover(_ on: Bool) {
    guard hovering != on else { return }
    hovering = on
    guard !look.current else { return }
    let from = (card.presentation() ?? card).borderColor
    card.borderColor = borderColor(current: false)
    MotionLedger.shared.start(
      .buttonHover, target: id,
      [
        .init(
          layer: card, key: "hover",
          animation: Motion.ease(
            "borderColor", from: from, to: card.borderColor, duration: Motion.hoverBorder))
      ])
  }

  /// The new preview fades in over the old one.
  private func crossfade() {
    let fade = CATransition()
    fade.type = .fade
    fade.duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.crossfade
    fade.timingFunction = Motion.easeOut
    MotionLedger.shared.start(
      .previewCrossfade, target: id, [.init(layer: image, key: "contents", animation: fade)])
  }

  /// The first preview dissolves the placeholder text into the image. A hidden layer shows no
  /// animation, so the placeholders stay on until the fade is over.
  private func fadeInFirstPreview(to opacity: Float) {
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.crossfade
    let placeholders = [placeholderTitle, placeholderOrigin]
    for text in placeholders {
      text.isHidden = false
      text.opacity = 0
    }
    var parts: [MotionLedger.Part] = [
      .init(
        layer: image, key: "opacity",
        animation: Motion.ease("opacity", from: 0, to: opacity, duration: duration))
    ]
    parts += placeholders.map {
      .init(
        layer: $0, key: "opacity",
        animation: Motion.ease("opacity", from: 1, to: 0, duration: duration))
    }
    MotionLedger.shared.start(.previewCrossfade, target: id, parts) { [weak self] _ in
      guard let self else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for text in placeholders {
        text.isHidden = look.hasImage
        text.opacity = 1
      }
      CATransaction.commit()
    }
  }

  /// A stale preview dims, a fresh one comes back: the card must not look current when it is not.
  private func dim(to opacity: Float) {
    let from = (image.presentation() ?? image).opacity
    let duration = MotionLedger.shared.reduced() ? Motion.reducedFade : Motion.crossfade
    MotionLedger.shared.start(
      .previewStale, target: id,
      [
        .init(
          layer: image, key: "opacity",
          animation: Motion.ease("opacity", from: from, to: opacity, duration: duration))
      ])
  }

  static func attributed(
    _ text: String, _ font: NSFont, _ color: NSColor, align: NSTextAlignment = .left
  ) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byTruncatingTail
    return NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
  }
}
