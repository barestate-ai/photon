import BarestateCore
import CoreImage
import Foundation
import Testing

struct RemoteTests {
  private func status(_ name: String) -> Data {
    Data(#"{"Version":"1","Self":{"DNSName":"\#(name)","HostName":"x"},"Peer":{}}"#.utf8)
  }

  @Test func theHostIsTheSelfNameWithoutItsTrailingDot() {
    #expect(
      Remote.host(fromTailscaleStatus: status("my-mac.example-tailnet.ts.net."))
        == "my-mac.example-tailnet.ts.net")
    #expect(Remote.host(fromTailscaleStatus: status("my-mac.example-tailnet.ts.net")) != nil)
  }

  @Test func noHostComesFromAnEmptyOrBrokenStatus() {
    #expect(Remote.host(fromTailscaleStatus: status("")) == nil)
    #expect(Remote.host(fromTailscaleStatus: Data("not json".utf8)) == nil)
    #expect(Remote.host(fromTailscaleStatus: Data(#"{"Self":{}}"#.utf8)) == nil)
  }

  @Test func theFunnelCommandsNameOnlyTheBarestatePathOnPort10000() {
    #expect(
      Remote.funnelMount(gatewayPort: 47820)
        == ["funnel", "--bg", "--https=10000", "--set-path=/barestate", "http://127.0.0.1:47820"])
    #expect(
      Remote.funnelUnmount == ["funnel", "--https=10000", "--set-path=/barestate", "off"])
  }

  @Test func theTokenSitsOnlyInTheFragment() throws {
    let token = String(repeating: "ab", count: 32)
    let text = Remote.pairingURL(host: "my-mac.example-tailnet.ts.net", token: token)
    #expect(text == "https://my-mac.example-tailnet.ts.net:10000/barestate/#t=\(token)")
    let parts = try #require(URLComponents(string: text))
    #expect(parts.path == "/barestate/")
    #expect(parts.query == nil)
    #expect(parts.fragment == "t=\(token)")
  }

  @Test func aQRCodeDecodesBackToItsText() throws {
    let text = Remote.pairingURL(host: "my-mac.example-tailnet.ts.net", token: "0123abcd")
    let image = try #require(
      QRCode.image(
        text, dark: CIColor(red: 0.03, green: 0.09, blue: 0.09),
        light: CIColor(red: 1, green: 0.996, blue: 0.98)))
    let detector = try #require(
      CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let found = detector.features(in: CIImage(cgImage: image)).compactMap {
      ($0 as? CIQRCodeFeature)?.messageString
    }
    #expect(found == [text])
    #expect(image.width >= 300)
  }
}
