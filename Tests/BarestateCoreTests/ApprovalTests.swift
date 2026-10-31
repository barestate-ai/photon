import BarestateCore
import CryptoKit
import Foundation
import Testing

struct ApprovalTests {
  private func sha(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private let click = ApprovalBinding(
    tabId: "t1", epoch: 3, documentKey: "F:L1", ref: 8, kind: .click, textHash: nil)

  @Test func theTokenIsTheSHA256OfTheBoundFieldsInOrder() {
    #expect(click.token == sha("t1|3|F:L1|8|click|"))
    let typed = ApprovalBinding(
      tabId: "t1", epoch: 3, documentKey: "F:L1", ref: 8, kind: .type, textHash: "ab12")
    #expect(typed.token == sha("t1|3|F:L1|8|type|ab12"))
  }

  @Test func everyFieldChangesTheToken() {
    let others = [
      ApprovalBinding(
        tabId: "t2", epoch: 3, documentKey: "F:L1", ref: 8, kind: .click, textHash: nil),
      ApprovalBinding(
        tabId: "t1", epoch: 4, documentKey: "F:L1", ref: 8, kind: .click, textHash: nil),
      ApprovalBinding(
        tabId: "t1", epoch: 3, documentKey: "F:L2", ref: 8, kind: .click, textHash: nil),
      ApprovalBinding(
        tabId: "t1", epoch: 3, documentKey: "F:L1", ref: 9, kind: .click, textHash: nil),
      ApprovalBinding(
        tabId: "t1", epoch: 3, documentKey: "F:L1", ref: 8, kind: .press, textHash: nil),
      ApprovalBinding(
        tabId: "t1", epoch: 3, documentKey: "F:L1", ref: 8, kind: .click, textHash: "x"),
    ]
    #expect(Set(others.map(\.token) + [click.token]).count == 7)
  }

  @Test func aMovedBindingNamesWhatMoved() {
    var now = click
    #expect(click.staleReason(against: now) == nil)
    now = ApprovalBinding(
      tabId: "t1", epoch: 4, documentKey: "F:L1", ref: 8, kind: .click, textHash: nil)
    #expect(click.staleReason(against: now) == .epoch)
    now = ApprovalBinding(
      tabId: "t1", epoch: 3, documentKey: "F:L2", ref: 8, kind: .click, textHash: nil)
    #expect(click.staleReason(against: now) == .documentKey)
    now = ApprovalBinding(
      tabId: "t1", epoch: 4, documentKey: "F:L2", ref: 8, kind: .click, textHash: nil)
    #expect(click.staleReason(against: now) == .epoch)
  }
}
