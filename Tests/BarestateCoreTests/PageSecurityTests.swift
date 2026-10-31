import Testing

@testable import BarestateCore

@Suite struct PageSecurityTests {
  private func make(
    _ url: String, title: String = "T", ssl: SSLState = .unknown, failure: String? = nil
  ) -> PageCaption? {
    PageCaption.make(url: url, title: title, ssl: ssl, certificateFailure: failure)
  }

  @Test func httpsWithAValidConnectionIsSecure() {
    #expect(make("https://example.com/a", ssl: .secure)?.security == .secure)
    #expect(make("https://example.com/a", ssl: .secure)?.host == "example.com")
  }

  @Test func httpsNeverCountsAsSecureWithoutAValidConnection() {
    #expect(make("https://example.com/", ssl: .unknown)?.security == .notSecure)
    #expect(make("https://example.com/", ssl: .insecure)?.security == .notSecure)
  }

  @Test func plainHttpIsNotSecureEvenIfTheEngineSaysSecure() {
    #expect(make("http://127.0.0.1:47810/a.html", ssl: .secure)?.security == .notSecure)
    #expect(make("http://127.0.0.1:47810/a.html")?.host == "127.0.0.1:47810")
  }

  @Test func aLocalFileShowsItsFileName() {
    let caption = make("file:///tmp/dir/page%20one.html")
    #expect(caption?.security == .localFile)
    #expect(caption?.host == "page one.html")
  }

  @Test func aCertificateErrorWinsOverSecureAndNamesTheRefusedSite() {
    #expect(make("https://127.0.0.1:47841/", ssl: .certificateError)?.security == .certificateError)
    let failed = make(
      "chrome-error://chromewebdata/", ssl: .secure, failure: "https://127.0.0.1:47841/")
    #expect(failed?.security == .certificateError)
    #expect(failed?.host == "127.0.0.1:47841")
  }

  @Test func theTitleFallsBackToTheHostAndBlankPagesHaveNoCaption() {
    #expect(make("https://example.com/", title: "")?.title == "example.com")
    #expect(make("about:blank") == nil)
    #expect(make("") == nil)
    #expect(make("chrome-error://chromewebdata/") == nil)
  }

  @Test func onlyTheCertificateBlockOfNetErrorsCountsAsACertificateFailure() {
    #expect(SSLState.isCertificateNetError(-202))
    #expect(SSLState.isCertificateNetError(-200))
    #expect(!SSLState.isCertificateNetError(-105))
    #expect(!SSLState.isCertificateNetError(-21))
  }
}
