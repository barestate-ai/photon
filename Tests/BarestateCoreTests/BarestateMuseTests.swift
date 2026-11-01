import BarestateCore
import Foundation
import Testing

/// The token store (file form; the Keychain form is normal-use only and tests never touch it)
/// and the invite-code registration call against a stubbed transport.
struct BarestateMuseTests {
  private final class Stub: @unchecked Sendable {
    var request: URLRequest?
    var reply: (Int, String) = (201, #"{"device_token":"tok-1"}"#)
    var fails = false

    var transport: ModelTransport {
      { [self] request, _ in
        self.request = request
        if fails { throw URLError(.notConnectedToInternet) }
        let (status, body) = reply
        let response = HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
      }
    }
  }

  private func tempFile() -> String {
    NSTemporaryDirectory() + "bs-muse-\(UUID().uuidString)/device-token"
  }

  @Test func theFileStoreRoundTripsATokenAt0600() throws {
    let file = tempFile()
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(
        atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path)
    }
    let store = BarestateMuse.TokenStore(file: file)
    #expect(store.read() == nil)
    try store.store("dev-token")
    #expect(store.read() == "dev-token")
    let attributes = try FileManager.default.attributesOfItem(atPath: file)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    try store.store("dev-token-2")  // replacing works
    #expect(store.read() == "dev-token-2")
    store.remove()
    #expect(store.read() == nil)
    store.remove()  // removing twice is fine
  }

  @Test func theBaseURLAndDevicesURLFollowTheOverride() {
    #expect(BarestateMuse.baseURL([:]) == "https://api.barestate.xyz/v1/muse")
    #expect(BarestateMuse.devicesURL([:]) == "https://api.barestate.xyz/v1/devices")
    let env = ["BARESTATE_API_URL": "http://127.0.0.1:47881/v1/muse"]
    #expect(BarestateMuse.baseURL(env) == "http://127.0.0.1:47881/v1/muse")
    #expect(BarestateMuse.devicesURL(env) == "http://127.0.0.1:47881/v1/devices")
  }

  @Test func registrationPostsTheCodeAndTheDeviceName() async throws {
    let stub = Stub()
    let token = try await BarestateMuse.register(
      inviteCode: "CODE-123", deviceName: "Akshat's Mac", environment: [:],
      transport: stub.transport)
    #expect(token == "tok-1")
    let request = try #require(stub.request)
    #expect(request.url?.absoluteString == "https://api.barestate.xyz/v1/devices")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = JSON.parse(request.httpBody ?? Data())
    #expect(body?["invite_code"]?.string == "CODE-123")
    #expect(body?["device_name"]?.string == "Akshat's Mac")
  }

  @Test func anUnknownInviteCodeIsTheServersMessage() async {
    let stub = Stub()
    stub.reply = (403, #"{"error":{"message":"Unknown invite code."}}"#)
    await #expect(throws: BarestateMuse.ConnectError.refused("Unknown invite code.")) {
      try await BarestateMuse.register(
        inviteCode: "nope", deviceName: "Mac", environment: [:], transport: stub.transport)
    }
  }

  @Test func aTransportFailureReadsAsOffline() async {
    let stub = Stub()
    stub.fails = true
    await #expect(throws: BarestateMuse.ConnectError.offline) {
      try await BarestateMuse.register(
        inviteCode: "CODE-123", deviceName: "Mac", environment: [:], transport: stub.transport)
    }
  }

  @Test func aReplyWithoutATokenIsMalformed() async {
    let stub = Stub()
    stub.reply = (201, "{}")
    await #expect(throws: BarestateMuse.ConnectError.malformed) {
      try await BarestateMuse.register(
        inviteCode: "CODE-123", deviceName: "Mac", environment: [:], transport: stub.transport)
    }
  }

  @Test func errorLinesAreOneClearSentence() {
    #expect(
      BarestateMuse.ConnectError.offline.description
        == "Could not reach the Barestate API. Check the connection and try again.")
    #expect(
      BarestateMuse.ConnectError.refused("Unknown invite code.").description
        == "Unknown invite code.")
    #expect(
      BarestateMuse.ConnectError.malformed.description
        == "The Barestate API answered in an unexpected way.")
    #expect(
      BarestateMuse.ConnectError.storeFailed.description
        == "The device token could not be stored on this Mac.")
  }
}
