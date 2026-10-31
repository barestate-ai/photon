import BarestateCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private func image(_ width: Int, _ height: Int) -> CGImage {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}

private func preview(_ key: String = "d1", _ width: Int = 10, _ height: Int = 10) -> Preview {
  Preview(documentKey: key, image: image(width, height))
}

private func jpeg(_ width: Int, _ height: Int) -> Data {
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(
    data, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image(width, height), nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

struct PreviewCacheTests {
  private func offer(_ cache: inout PreviewCache, _ node: String, key: String = "d1", w: Int = 10) {
    _ = cache.offer(preview(key, w, w), node: node, currentKey: key)
  }

  @Test func startsAtTheDocumentedLimits() {
    let cache = PreviewCache()
    #expect(cache.limits == PreviewCache.Limits(count: 64, bytes: 48 << 20))
  }

  @Test func theShippedLimitsHoldForSeventyEntries() {
    var cache = PreviewCache()
    // 480 x 480 x 4 = 921 600 bytes: 64 of them would be 56 MiB, so bytes bind before count.
    for index in 0..<70 {
      offer(&cache, "n\(index)", w: 480)
      #expect(cache.count <= 64)
      #expect(cache.bytes <= 48 << 20)
    }
    #expect(cache.count == (48 << 20) / (480 * 480 * 4))
    #expect(cache.bytes == cache.count * 480 * 480 * 4)
  }

  @Test func countBoundEvictsTheLeastRecentlyUsed() {
    var cache = PreviewCache()
    cache.limits = .init(count: 4, bytes: 2 << 20)
    for index in 0..<4 { offer(&cache, "n\(index)") }
    #expect(cache.preview(for: "n0") != nil)
    offer(&cache, "n4")
    #expect(cache.count == 4)
    #expect(cache.state(of: "n0") == .fresh)
    #expect(cache.state(of: "n1") == .none)
    #expect(cache.evictions == 1)
  }

  @Test func byteBoundEvictsUntilItFits() {
    var cache = PreviewCache()
    cache.limits = .init(count: 64, bytes: 1_000)
    offer(&cache, "a", w: 10)
    offer(&cache, "b", w: 10)
    #expect(cache.bytes == 800)
    offer(&cache, "c", w: 15)
    #expect(cache.bytes <= 1_000)
    #expect(cache.state(of: "c") == .fresh)
    #expect(cache.count == 1)
  }

  @Test func aSingleImageOverTheByteLimitIsRefusedAndKeepsTheOldOne() {
    var cache = PreviewCache()
    cache.limits = .init(count: 4, bytes: 1_000)
    offer(&cache, "a")
    let outcome = cache.offer(preview("d1", 20, 20), node: "a", currentKey: "d1")
    #expect(outcome == .tooLarge)
    #expect(cache.bytes == 400)
    #expect(cache.captures == 1)
  }

  @Test func loweringTheLimitsEvictsImmediately() {
    var cache = PreviewCache()
    for index in 0..<6 { offer(&cache, "n\(index)") }
    cache.limits = .init(count: 2, bytes: 1 << 20)
    #expect(cache.count == 2)
    #expect(cache.state(of: "n5") == .fresh)
    #expect(cache.state(of: "n4") == .fresh)
  }

  @Test func aResultForAnOldDocumentIsDroppedAndCounted() {
    var cache = PreviewCache()
    offer(&cache, "a", key: "d1")
    let before = (cache.count, cache.bytes)
    let outcome = cache.offer(preview("d1"), node: "a", currentKey: "d2")
    #expect(outcome == .rejectedStale)
    #expect(cache.rejectedStale == 1)
    #expect(cache.captures == 1)
    #expect(cache.count == before.0 && cache.bytes == before.1)
  }

  @Test func aResultWithNoCurrentDocumentIsDropped() {
    var cache = PreviewCache()
    #expect(cache.offer(preview(), node: "a", currentKey: nil) == .rejectedStale)
    #expect(cache.state(of: "a") == .none)
  }

  @Test func navigationMarksStaleAndAFreshCaptureClearsIt() {
    var cache = PreviewCache()
    offer(&cache, "a", key: "d1")
    cache.markStale("a")
    #expect(cache.state(of: "a") == .stale)
    #expect(cache.documentKey(of: "a") == "d1")
    #expect(cache.preview(for: "a") != nil)
    offer(&cache, "a", key: "d2")
    #expect(cache.state(of: "a") == .fresh)
    #expect(cache.documentKey(of: "a") == "d2")
    #expect(cache.count == 1)
  }

  @Test func aStaleNodeWithoutAnImageStaysStaleAfterARejection() {
    var cache = PreviewCache()
    cache.markStale("a")
    _ = cache.offer(preview("d1"), node: "a", currentKey: "d2")
    #expect(cache.state(of: "a") == .stale)
    #expect(cache.count == 0)
  }

  @Test func retainDropsNodesThatLeftTheGraph() {
    var cache = PreviewCache()
    offer(&cache, "a")
    offer(&cache, "b")
    cache.markStale("c")
    cache.retain(["a"])
    #expect(cache.count == 1)
    #expect(cache.bytes == 400)
    #expect(cache.state(of: "b") == .none)
    #expect(cache.state(of: "c") == .none)
  }

  @Test func replacingAnEntryKeepsTheByteAccountExact() {
    var cache = PreviewCache()
    offer(&cache, "a", w: 10)
    offer(&cache, "a", w: 20)
    #expect(cache.bytes == 1_600)
    #expect(cache.count == 1)
  }
}

struct PreviewDecoderTests {
  /// Red above `split`, blue below, so a crop's origin shows in its pixels.
  private func twoTone(_ width: Int, _ height: Int, split: Int) -> Data {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: height - split, width: width, height: split))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  private func red(_ image: CGImage, row: Int) -> Bool {
    let row = image.cropping(to: CGRect(x: 0, y: row, width: 1, height: 1))!
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(row, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    return pixel[0] > 200 && pixel[2] < 60
  }

  @Test func aWideViewportIsScaledToTheCardsHeightAndCutFromTheLeft() throws {
    let result = try #require(
      PreviewDecoder.decode(
        jpeg(800, 400), documentKey: "d1", cardWidth: 200, cardHeight: 150))
    #expect(result.image.width == 200 && result.image.height == 150)
    #expect(result.bytes == 200 * 150 * 4)
    #expect(result.documentKey == "d1")
  }

  @Test func aTallViewportIsScaledToTheCardsWidthAndCutFromTheTop() throws {
    let result = try #require(
      PreviewDecoder.decode(
        twoTone(400, 800, split: 300), documentKey: "d1", cardWidth: 200, cardHeight: 100))
    #expect(result.image.width == 200 && result.image.height == 100)
    #expect(red(result.image, row: 0) && red(result.image, row: 99))
  }

  @Test func garbageIsNotAPreview() {
    #expect(
      PreviewDecoder.decode(Data([1, 2, 3]), documentKey: "d1", cardWidth: 200, cardHeight: 100)
        == nil)
  }
}

struct PreviewCaptureTests {
  @Test func theScreenshotIsTheViewportAsDisplayedWithNoClipOrEmulation() {
    let params = PreviewCapture.screenshot
    #expect(params["format"]?.string == "jpeg" && params["quality"]?.int == 60)
    for forbidden in ["clip", "captureBeyondViewport"] { #expect(params[forbidden] == nil) }
  }

  @Test func theDocumentKeyIsTheMainFramesIdAndLoader() throws {
    let tree: JSON = ["frameTree": ["frame": ["id": "F", "loaderId": "L"]]]
    #expect(try PageKeys.documentKey(frameTree: tree) == "F:L")
  }
}
