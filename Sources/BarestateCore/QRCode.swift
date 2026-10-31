import CoreImage

public enum QRCode {
  /// A QR code of `text` with square modules at least 360 px across and a four-module quiet
  /// zone, in `dark` on `light`.
  public static func image(_ text: String, dark: CIColor, light: CIColor) -> CGImage? {
    guard let generator = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    generator.setValue(Data(text.utf8), forKey: "inputMessage")
    generator.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = generator.outputImage else { return nil }
    let scale = max(1, 360 / Int(code.extent.width))
    let sized = code.samplingNearest().transformed(
      by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
    guard let tint = CIFilter(name: "CIFalseColor") else { return nil }
    tint.setValue(sized, forKey: kCIInputImageKey)
    tint.setValue(dark, forKey: "inputColor0")
    tint.setValue(light, forKey: "inputColor1")
    guard let tinted = tint.outputImage else { return nil }
    let quiet = CGFloat(4 * scale)
    let page = CIImage(color: light).cropped(to: tinted.extent.insetBy(dx: -quiet, dy: -quiet))
    let result = tinted.composited(over: page)
    return CIContext().createCGImage(result, from: result.extent)
  }
}
