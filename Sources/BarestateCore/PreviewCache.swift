import CoreGraphics
import Foundation
import ImageIO

public enum PreviewState: String, Sendable {
  case none, fresh, stale
}

/// A decoded page image stamped with the document it was captured from.
public struct Preview: @unchecked Sendable {
  public let documentKey: String
  public let image: CGImage

  public init(documentKey: String, image: CGImage) {
    self.documentKey = documentKey
    self.image = image
  }

  /// Decoded size, which is what the cache bounds; the JPEG it came from is gone.
  public var bytes: Int { image.width * image.height * 4 }
}

/// Memory-only previews per node, least recently used out first. A navigation marks a node
/// stale (its image stays, dimmed, until a capture of the new document replaces it), and a
/// capture is accepted only if its document is still the tab's current one.
public struct PreviewCache: Sendable {
  public struct Limits: Equatable, Sendable {
    public var count: Int
    public var bytes: Int

    public init(count: Int, bytes: Int) {
      self.count = count
      self.bytes = bytes
    }
  }

  public enum Outcome: Equatable, Sendable {
    case stored, rejectedStale, tooLarge
  }

  public static let defaultLimits = Limits(count: 64, bytes: 48 << 20)

  public var limits = PreviewCache.defaultLimits {
    didSet { evict() }
  }
  public private(set) var bytes = 0
  public private(set) var captures = 0
  public private(set) var rejectedStale = 0
  public private(set) var evictions = 0
  private var entries: [String: Preview] = [:]
  // ponytail: oldest first and scanned linearly; the count limit keeps it near 64 entries.
  private var order: [String] = []
  private var stale: Set<String> = []

  public init() {}

  public var count: Int { entries.count }

  public func state(of node: String) -> PreviewState {
    if stale.contains(node) { return .stale }
    return entries[node] == nil ? .none : .fresh
  }

  public func documentKey(of node: String) -> String? { entries[node]?.documentKey }

  /// Viewing a preview makes it the most recently used.
  public mutating func preview(for node: String) -> Preview? {
    guard let found = entries[node] else { return nil }
    touch(node)
    return found
  }

  /// `currentKey` is the tab's document now; a result for any other document is dropped.
  public mutating func offer(_ preview: Preview, node: String, currentKey: String?) -> Outcome {
    guard preview.documentKey == currentKey else {
      rejectedStale += 1
      return .rejectedStale
    }
    guard preview.bytes <= limits.bytes else { return .tooLarge }
    if let old = entries[node] { bytes -= old.bytes }
    entries[node] = preview
    bytes += preview.bytes
    stale.remove(node)
    touch(node)
    captures += 1
    evict()
    return .stored
  }

  public mutating func markStale(_ node: String) {
    stale.insert(node)
  }

  /// Drops everything for nodes that left the graph.
  public mutating func retain(_ nodes: Set<String>) {
    for node in entries.keys where !nodes.contains(node) { remove(node) }
    stale.formIntersection(nodes)
  }

  private mutating func remove(_ node: String) {
    guard let old = entries.removeValue(forKey: node) else { return }
    bytes -= old.bytes
    order.removeAll { $0 == node }
  }

  private mutating func touch(_ node: String) {
    order.removeAll { $0 == node }
    order.append(node)
  }

  private mutating func evict() {
    while entries.count > limits.count || bytes > limits.bytes, let oldest = order.first {
      remove(oldest)
      evictions += 1
    }
  }
}

public enum PreviewDecoder {
  /// ImageIO decodes the viewport straight to a thumbnail that covers the card, and the card's
  /// aspect is cut from its top left. The full-size image never exists and nothing is decoded
  /// lazily on the main thread at draw time.
  public static func decode(
    _ jpeg: Data, documentKey: String, cardWidth: Int, cardHeight: Int
  ) -> Preview? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = size[kCGImagePropertyPixelWidth] as? Int,
      let height = size[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return nil }
    let scale = max(Double(cardWidth) / Double(width), Double(cardHeight) / Double(height))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(width, height)) * scale).rounded(.up)),
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    // Redrawn rather than cropped: a cropped image keeps the whole thumbnail alive, and the cache
    // bounds what it holds by the card's bytes.
    let (w, h) = (min(cardWidth, thumbnail.width), min(cardHeight, thumbnail.height))
    guard
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(
      thumbnail,
      in: CGRect(
        x: 0, y: h - thumbnail.height, width: thumbnail.width, height: thumbnail.height))
    guard let card = context.makeImage() else { return nil }
    return Preview(documentKey: documentKey, image: card)
  }
}

public enum PreviewCapture {
  public struct Failure: Error, Equatable {
    public let message: String

    public init(message: String) {
      self.message = message
    }
  }

  /// `Page.captureScreenshot` of the viewport as displayed. Anything that sets a `clip`, captures
  /// beyond the viewport or emulates a size makes Chromium resize the page for the copy, so the
  /// page sees `resize` events and relayouts; the crop to the card happens in `PreviewDecoder`.
  public static let screenshot: JSON = [
    "format": "jpeg", "quality": 60, "fromSurface": true, "optimizeForSpeed": true,
  ]
}
