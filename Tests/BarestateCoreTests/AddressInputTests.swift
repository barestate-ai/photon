import BarestateCore
import Testing

struct AddressInputTests {
  private let duck = "https://duckduckgo.com/?q=%s"

  private func resolve(_ text: String) -> String? {
    AddressInput.resolve(text, searchTemplate: duck)
  }

  @Test func fullURLsPassThrough() {
    #expect(resolve("http://127.0.0.1:47810/input.html") == "http://127.0.0.1:47810/input.html")
    #expect(resolve("  https://example.com/a?b=c#d ") == "https://example.com/a?b=c#d")
    #expect(resolve("about:blank") == "about:blank")
  }

  @Test func aHostWithATopLevelDomainLoadsOverHTTPS() {
    #expect(resolve("example.com") == "https://example.com")
    #expect(resolve("www.example.co.uk/path?q=1") == "https://www.example.co.uk/path?q=1")
    #expect(resolve("example.com:8443/x") == "https://example.com:8443/x")
  }

  @Test func localhostAndIPAddressesLoadOverHTTP() {
    #expect(resolve("localhost:47810/a.html") == "http://localhost:47810/a.html")
    #expect(resolve("localhost") == "http://localhost")
    #expect(resolve("127.0.0.1:47810") == "http://127.0.0.1:47810")
  }

  @Test func everythingElseIsASearch() {
    #expect(resolve("kyoto hotels") == "https://duckduckgo.com/?q=kyoto+hotels")
    #expect(resolve("kyoto") == "https://duckduckgo.com/?q=kyoto")
    #expect(resolve("what is 1+1?") == "https://duckduckgo.com/?q=what+is+1%2B1%3F")
    #expect(resolve("example.com is down") == "https://duckduckgo.com/?q=example.com+is+down")
    #expect(resolve("a.b") == "https://duckduckgo.com/?q=a.b")
  }

  @Test func scriptURLsAreSearchesNotNavigations() {
    #expect(resolve("javascript:alert(1)") == "https://duckduckgo.com/?q=javascript%3Aalert%281%29")
  }

  @Test func contentSchemesAreSearchesEvenWithSlashesCaseOrControlCharacters() {
    for typed in [
      "javascript://%0Aalert(1)", "JavaScript:alert(1)", "java\nscript://x", "vbscript://x",
      "data:text/html,<b>x</b>", "data://text/html,x",
    ] {
      #expect(resolve(typed)?.hasPrefix("https://duckduckgo.com/?q=") == true, "\(typed)")
    }
  }

  @Test func locationNamesAPlaceOrNothing() {
    #expect(AddressInput.location(" example.com ") == "https://example.com")
    #expect(AddressInput.location("localhost:47810") == "http://localhost:47810")
    #expect(AddressInput.location("https://example.com/a") == "https://example.com/a")
    #expect(AddressInput.location("kyoto hotels") == nil)
    #expect(AddressInput.location("javascript:alert(1)") == nil)
    #expect(AddressInput.location("") == nil)
  }

  @Test func searchURLSearchesEvenForAHostLikeQuery() {
    #expect(
      AddressInput.searchURL("kyoto hotels", template: "https://duckduckgo.com/?q=%s")
        == "https://duckduckgo.com/?q=kyoto+hotels")
    #expect(
      AddressInput.searchURL(" example.com ", template: "https://duckduckgo.com/?q=%s")
        == "https://duckduckgo.com/?q=example.com")
  }

  @Test func emptyInputResolvesToNothing() {
    #expect(resolve("") == nil)
    #expect(resolve("   ") == nil)
  }

  @Test func blankAndRecordablePagesAreTold() {
    #expect(AddressInput.isBlank(""))
    #expect(AddressInput.isBlank("about:blank"))
    #expect(!AddressInput.isBlank("https://example.com"))
    #expect(AddressInput.isRecordable("https://example.com/"))
    #expect(AddressInput.isRecordable("http://127.0.0.1:47810/a.html"))
    #expect(!AddressInput.isRecordable("about:blank"))
    #expect(!AddressInput.isRecordable("file:///etc/hosts"))
  }
}
