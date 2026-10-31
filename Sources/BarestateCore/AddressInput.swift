import Foundation

/// Turns what a person typed into the address field into a URL to load.
public enum AddressInput {
  /// A full URL passes through, a bare host loads, anything else is a search. Schemes that run
  /// script or carry a document (`javascript:`, `data:`) are searched for, never loaded.
  public static func resolve(_ text: String, searchTemplate: String) -> String? {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    return location(input) ?? searchURL(input, template: searchTemplate)
  }

  public static func searchURL(_ text: String, template: String) -> String {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return template.replacingOccurrences(of: "%s", with: encodeQuery(query))
  }

  /// The URL to load when the text names a place (a full URL or a bare host), else nil.
  public static func location(_ text: String) -> String? {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !runsContent(input),
      input.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        || input.hasPrefix("about:")
    {
      return input
    }
    if !input.isEmpty, !input.contains(where: \.isWhitespace), let scheme = scheme(forHostOf: input)
    {
      return scheme + input
    }
    return nil
  }

  /// A URL parser drops tabs and newlines anywhere in the text, so they are dropped here too.
  private static func runsContent(_ input: String) -> Bool {
    let compact = input.filter { !$0.isNewline && $0 != "\t" }.lowercased()
    return ["javascript:", "vbscript:", "data:"].contains { compact.hasPrefix($0) }
  }

  public static func isBlank(_ url: String) -> Bool {
    url.isEmpty || url == "about:blank"
  }

  /// History and the Recent row only keep pages that can be revisited from a web address.
  public static func isRecordable(_ url: String) -> Bool {
    let lowered = url.lowercased()
    return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
  }

  private static func scheme(forHostOf input: String) -> String? {
    var host = String(input.prefix { !"/?#".contains($0) })
    if let colon = host.lastIndex(of: ":") {
      let port = host[host.index(after: colon)...]
      guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else {
        return nil
      }
      host = String(host[..<colon])
    }
    if host == "localhost" || isIPv4(host) { return "http://" }
    return hasTopLevelDomain(host) ? "https://" : nil
  }

  private static func isIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4
      && parts.allSatisfy { $0.count <= 3 && $0.allSatisfy(\.isASCII) && Int($0) != nil }
      && parts.allSatisfy { (Int($0) ?? 256) <= 255 }
  }

  private static func hasTopLevelDomain(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, let last = labels.last else { return false }
    return labels.allSatisfy {
      !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
      && last.count >= 2 && last.allSatisfy(\.isLetter)
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~ ")

  private static func encodeQuery(_ text: String) -> String {
    (text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text)
      .replacingOccurrences(of: " ", with: "+")
  }
}
