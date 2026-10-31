import Foundation

/// What CEF reports about the visible navigation entry's connection, before the scheme is
/// considered.
public enum SSLState: Int32, Sendable {
  case unknown = 0
  case secure
  case certificateError
  case insecure

  /// Chromium's ERR_CERT_* block: a load that fails with one of these was refused for its
  /// certificate, and the error page that replaces it carries no certificate of its own.
  public static func isCertificateNetError(_ code: Int) -> Bool { (-217)...(-200) ~= code }
}

public enum PageSecurity: String, Sendable {
  case secure = "Secure"
  case notSecure = "Not secure"
  case localFile = "Local file"
  case certificateError = "Certificate error"
}

/// Which site is active and how far to trust it, shown under the page and in the launcher footer.
public struct PageCaption: Equatable, Sendable {
  public let title: String
  /// Host with an explicit port, or the file name for a local file.
  public let host: String
  public let security: PageSecurity

  /// `certificateFailure` is the address whose load failed on its certificate; Chromium swaps in
  /// an error page for it, so the tab's own URL no longer says which site was refused.
  public static func make(
    url: String, title: String, ssl: SSLState, certificateFailure: String? = nil
  ) -> PageCaption? {
    let shown = certificateFailure ?? url
    guard !AddressInput.isBlank(shown), let parts = URLComponents(string: shown),
      let scheme = parts.scheme?.lowercased()
    else { return nil }
    let security: PageSecurity
    let host: String
    switch scheme {
    case "file":
      security = .localFile
      host = (parts.path as NSString).lastPathComponent
    case "https", "http":
      guard let name = parts.host, !name.isEmpty else { return nil }
      host = parts.port.map { "\(name):\($0)" } ?? name
      if certificateFailure != nil || ssl == .certificateError {
        security = .certificateError
      } else {
        security = scheme == "https" && ssl == .secure ? .secure : .notSecure
      }
    default:
      return nil
    }
    return PageCaption(title: title.isEmpty ? host : title, host: host, security: security)
  }
}
