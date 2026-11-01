import Foundation
import Security

/// Barestate Muse (D74): a user without a model key of their own registers this Mac once with
/// an invite code; the device token then stands in for the key, with calls going through the
/// Barestate API proxy instead of Meta directly. The user's own key always wins (ModelClient).
public enum BarestateMuse {
  /// The deployed proxy (server/barestate-api); `BARESTATE_API_URL` overrides it.
  public static let defaultBaseURL = "https://api.barestate.xyz/v1/muse"
  /// The Keychain generic-password service holding the device token in normal use.
  public static let keychainService = "barestate-api"

  public static func baseURL(_ environment: [String: String]) -> String {
    environment["BARESTATE_API_URL"] ?? defaultBaseURL
  }

  /// Device registration lives next to the Muse proxy path.
  public static func devicesURL(_ environment: [String: String]) -> String {
    let base = baseURL(environment)
    return (base.hasSuffix("/v1/muse") ? String(base.dropLast("/v1/muse".count)) : base)
      + "/v1/devices"
  }

  /// A connect failure as the one clear line Settings shows.
  public enum ConnectError: Error, Equatable, CustomStringConvertible {
    case offline
    /// The proxy's own message (an unknown invite code, throttling).
    case refused(String)
    case malformed
    case storeFailed

    public var description: String {
      switch self {
      case .offline: "Could not reach the Barestate API. Check the connection and try again."
      case .refused(let message): message
      case .malformed: "The Barestate API answered in an unexpected way."
      case .storeFailed: "The device token could not be stored on this Mac."
      }
    }

    /// A static word for logs: `description` may carry the proxy's message verbatim, and a
    /// hostile one could echo the invite code, so the description never enters a log.
    public var logName: String {
      switch self {
      case .offline: "offline"
      case .refused: "refused"
      case .malformed: "malformed"
      case .storeFailed: "store-failed"
      }
    }
  }

  /// Where the device token lives: the login Keychain in normal use, or a 0600 file in the
  /// data dir under --test-hooks so a test never touches the Keychain.
  public struct TokenStore: Sendable {
    public let file: String?

    public init(file: String?) { self.file = file }

    public func read() -> String? {
      if let file {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: BarestateMuse.keychainService,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
        let data = item as? Data
      else { return nil }
      return String(data: data, encoding: .utf8)
    }

    public func store(_ token: String) throws {
      if let file {
        let manager = FileManager.default
        try? manager.removeItem(atPath: file)
        guard
          manager.createFile(
            atPath: file, contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600])
        else { throw ConnectError.storeFailed }
        return
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: BarestateMuse.keychainService,
      ]
      SecItemDelete(query as CFDictionary)  // replace any earlier token
      var add = query
      add[kSecValueData as String] = Data(token.utf8)
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
        throw ConnectError.storeFailed
      }
    }

    public func remove() {
      if let file {
        try? FileManager.default.removeItem(atPath: file)
        return
      }
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: BarestateMuse.keychainService,
        ] as CFDictionary)
    }
  }

  /// `POST /v1/devices` with the invite code and this Mac's name; the token comes back once and
  /// is never logged here.
  public static func register(
    inviteCode: String, deviceName: String, environment: [String: String],
    transport: ModelTransport = liveModelTransport
  ) async throws -> String {
    guard let url = URL(string: devicesURL(environment)) else { throw ConnectError.malformed }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      JSON.object([
        "invite_code": .string(inviteCode), "device_name": .string(deviceName),
      ]).serialized().utf8)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport(request, nil)
    } catch {
      throw ConnectError.offline
    }
    switch response.statusCode {
    case 200..<300:
      guard let token = JSON.parse(data)?["device_token"]?.string, !token.isEmpty else {
        throw ConnectError.malformed
      }
      return token
    default:
      throw ConnectError.refused(
        JSON.parse(data)?["error"]?["message"]?.string
          ?? "The Barestate API answered with status \(response.statusCode).")
    }
  }
}
