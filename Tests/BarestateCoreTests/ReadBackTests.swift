import BarestateCore
import Foundation
import Testing

struct ReadBackTests {
  private let before = PageSnapshot(
    href: "http://x/a", page: "p1", connected: true, shell: "s1", state: "false|on")

  private func after(
    href: String = "http://x/a", page: String = "p1", connected: Bool = true, shell: String = "s1",
    state: String = "false|on", focused: Bool = false, entry: Bool = false
  ) -> PageSnapshot {
    PageSnapshot(
      href: href, page: page, connected: connected, shell: shell, state: state, focused: focused,
      entry: entry)
  }

  private func verdict(_ later: PageSnapshot?, documentChanged: Bool = false) -> String {
    let outcome = ReadBack.click(before: before, after: later, documentChanged: documentChanged)
    #expect(outcome.verified == (outcome.verdict != "unchanged"))
    return outcome.verdict
  }

  @Test func aClickIsVerifiedByTheEffectItHad() {
    #expect(verdict(after(), documentChanged: true) == "document-changed")
    #expect(verdict(nil) == "element-gone")
    #expect(verdict(after(connected: false)) == "element-gone")
    #expect(verdict(after(href: "http://x/b")) == "url-changed")
    #expect(verdict(after(state: "true|on")) == "state-changed")
    #expect(verdict(after(shell: "s2")) == "element-changed")
    #expect(verdict(after(page: "p2")) == "page-changed")
  }

  @Test func aClickThatChangedNothingIsNotVerified() {
    #expect(verdict(after()) == "unchanged")
  }

  @Test func focusProvesAClickOnlyOnATextField() {
    #expect(verdict(after(focused: true, entry: true)) == "focused")
    #expect(verdict(after(focused: true)) == "unchanged")
  }

  @Test func theNearestEffectWinsWhenSeveralChanged() {
    #expect(verdict(after(href: "http://x/b", page: "p2", shell: "s2")) == "url-changed")
    #expect(verdict(after(page: "p2", shell: "s2")) == "element-changed")
  }

  @Test func typedTextLandsAtTheCaretExactly() {
    func expected(_ value: String, _ start: Int, _ end: Int, _ text: String) -> String {
      ReadBack.expectedValue(
        before: ReadBack.Caret(value: value, start: start, end: end), inserting: text)
    }
    #expect(expected("", 0, 0, "hi") == "hi")
    #expect(expected("abcd", 2, 2, "XY") == "abXYcd")
    #expect(expected("abcd", 1, 3, "XY") == "aXYd")
    #expect(expected("abcd", 4, 4, "!") == "abcd!")
  }

  @Test func offsetsCountUTF16UnitsAsThePageDoes() {
    // "🙂" is two UTF-16 units; a caret after it is offset 2.
    #expect(
      ReadBack.expectedValue(
        before: ReadBack.Caret(value: "🙂b", start: 2, end: 2), inserting: "X") == "🙂Xb")
  }

  @Test func offsetsPastTheEndAreClamped() {
    #expect(
      ReadBack.expectedValue(
        before: ReadBack.Caret(value: "ab", start: 9, end: 9), inserting: "X") == "abX")
  }

  @Test func aSelectionReadsBackFromThePagesAnswer() throws {
    let caret = try #require(
      ReadBack.Caret(json: ["value": "abc", "start": 1, "end": 2]))
    #expect(caret == ReadBack.Caret(value: "abc", start: 1, end: 2))
    #expect(ReadBack.Caret(json: .null) == nil)
    #expect(ReadBack.Caret(json: ["value": "abc"]) == nil)
  }
}
