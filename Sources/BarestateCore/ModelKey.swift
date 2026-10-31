import Foundation
import Security

/// Finds a model API key: the environment wins, then the `.env` file, then (for the Meta key)
/// the Keychain. Callers learn which source won; the value is never printed.
public enum ModelKey {
  public static let variable = "MODEL_API_KEY"
  public static let keychainService = "meta-model-api"

  public enum Source: String, Sendable { case environment, envFile, keychain }

  public struct Found: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let source: Source
    public let value: String
    public var description: String { "key from \(source.rawValue)" }
    public var debugDescription: String { description }
  }

  public static func resolve(
    variable: String = ModelKey.variable, environment: [String: String], envFile: String?,
    keychain: () -> String? = { nil }
  ) -> Found? {
    if let value = clean(environment[variable]) { return Found(source: .environment, value: value) }
    if let envFile, let value = fileValue(variable, in: envFile) {
      return Found(source: .envFile, value: value)
    }
    if let value = clean(keychain()) { return Found(source: .keychain, value: value) }
    return nil
  }

  /// The generic password `meta-model-api`, or nil when there is none.
  public static func readKeychain() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func fileValue(_ variable: String, in file: String) -> String? {
    for line in file.split(whereSeparator: \.isNewline) {
      var text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("export ") { text = String(text.dropFirst(7)) }
      guard text.hasPrefix(variable + "="),
        let value = clean(String(text.dropFirst(variable.count + 1)))
      else { continue }
      return value
    }
    return nil
  }

  private static func clean(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
    return value.isEmpty ? nil : value
  }
}
