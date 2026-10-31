// Assembles the demo video from the frames scripts/capture-demo.py saved (no installs, AVFoundation only).
//
//   swift scripts/make-video.swift build  <capture.tsv> <out.mp4>
//   swift scripts/make-video.swift frame  <video> <seconds> <out.png>
//
// build: reads capture.tsv (UTC time, offset, file, what, hold seconds). Frames that share a `what` form a
// run of a wait; a run longer than `maxRun` frames keeps `maxRun` evenly spaced ones, each held `waitHold`
// seconds, so waiting is shown shortened. Other frames are held for their own `hold`.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

let maxRun = 12
let waitHold = 0.5
let width = 1440
let height = 900

struct Row {
  let path: String
  let what: String
  let hold: Double
}

func rows(_ tsv: String) -> [Row] {
  let text = (try? String(contentsOfFile: tsv, encoding: .utf8)) ?? ""
  return text.split(separator: "\n").compactMap { line in
    let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard c.count == 5, let hold = Double(c[4]) else { return nil }
    return Row(path: c[2], what: c[3], hold: hold)
  }
}

func plan(_ all: [Row]) -> [(path: String, seconds: Double)] {
  var out: [(String, Double)] = []
  var i = 0
  while i < all.count {
    var j = i
    while j < all.count && all[j].what == all[i].what { j += 1 }
    let run = Array(all[i..<j])
    if run.count > maxRun {
      for k in 0..<maxRun {
        out.append((run[k * (run.count - 1) / (maxRun - 1)].path, waitHold))
      }
    } else {
      out += run.map { ($0.path, $0.hold) }
    }
    i = j
  }
  return out
}

func pixelBuffer(_ path: String) -> CVPixelBuffer? {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    image.width == width, image.height == height
  else { return nil }
  var buffer: CVPixelBuffer?
  CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
  guard let buffer else { return nil }
  CVPixelBufferLockBaseAddress(buffer, [])
  let context = CGContext(
    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
  context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  CVPixelBufferUnlockBaseAddress(buffer, [])
  return buffer
}

func build(_ tsv: String, _ output: String) -> Int32 {
  let frames = plan(rows(tsv))
  try? FileManager.default.removeItem(atPath: output)
  guard let writer = try? AVAssetWriter(url: URL(fileURLWithPath: output), fileType: .mp4) else { return 1 }
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000],
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input, sourcePixelBufferAttributes: nil)
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  var at = 0.0
  var last: CVPixelBuffer?
  for (path, seconds) in frames {
    guard let buffer = pixelBuffer(path) else {
      FileHandle.standardError.write(Data("not a \(width)x\(height) image: \(path)\n".utf8))
      return 1
    }
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    adaptor.append(buffer, withPresentationTime: CMTime(seconds: at, preferredTimescale: 600))
    last = buffer
    at += seconds
  }
  // A sample lasts until the next one starts, so the last frame needs a closing sample to be held.
  if let last {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    adaptor.append(last, withPresentationTime: CMTime(seconds: at, preferredTimescale: 600))
  }
  input.markAsFinished()
  writer.endSession(atSourceTime: CMTime(seconds: at + 0.05, preferredTimescale: 600))
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  print("frames \(frames.count), \(at) s, status \(writer.status.rawValue)")
  return writer.status == .completed ? 0 : 1
}

func frame(_ video: String, _ seconds: Double, _ output: String) -> Int32 {
  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: video)))
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  guard let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil),
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
  else { return 1 }
  CGImageDestinationAddImage(destination, image, nil)
  return CGImageDestinationFinalize(destination) ? 0 : 1
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (4, "build"): exit(build(args[2], args[3]))
case (5, "frame"): exit(frame(args[2], Double(args[3]) ?? 0, args[4]))
default:
  FileHandle.standardError.write(Data("usage: make-video.swift build <tsv> <out> | frame <video> <s> <png>\n".utf8))
  exit(2)
}
