import BarestateCore
import Testing

private func element(
  _ ref: Int, _ name: String, role: String = "button", value: String? = nil,
  interactive: Bool = true
) -> Element {
  Element(
    ref: ref, role: role, name: name, value: value, bounds: Rect(x: 0, y: 0, w: 10, h: 10),
    interactive: interactive, sensitive: false)
}

struct InstructionMatchTests {
  @Test func rolesAndFillerWordsAreNotContent() {
    #expect(InstructionMatch.tokens("Click the Save button") == ["save"])
    #expect(InstructionMatch.tokens("tap on 'Sign-in' link, please") == ["sign"])
  }

  @Test func theBestElementIsTheTightestNameThatCoversTheInstruction() {
    let elements = [element(1, "Save draft"), element(2, "Save"), element(3, "Cancel")]
    #expect(InstructionMatch.best(instruction: "Click Save", in: elements)?.ref == 2)
  }

  @Test func nothingMatchesWhenNoNameSharesAWord() {
    let elements = [element(1, "Cancel"), element(2, "Count")]
    #expect(InstructionMatch.best(instruction: "Click Save", in: elements) == nil)
  }

  @Test func anElementThatCannotBeActedOnNeverMatches() {
    let elements = [element(1, "Save", interactive: false)]
    #expect(InstructionMatch.best(instruction: "Click Save", in: elements) == nil)
  }

  @Test func twoEquallyGoodElementsAreAmbiguousNotGuessed() {
    let elements = [element(1, "Save"), element(2, "Save")]
    #expect(InstructionMatch.best(instruction: "Click Save", in: elements) == nil)
  }

  @Test func theValueCountsAsAName() {
    let elements = [element(1, "", role: "textbox", value: "jane@example.com")]
    #expect(
      InstructionMatch.best(instruction: "the jane@example.com field", in: elements)?.ref == 1)
  }

  @Test func aSingleSharedWordOfALongInstructionIsNotEnough() {
    let elements = [element(1, "Order")]
    #expect(InstructionMatch.best(instruction: "submit the order form now", in: elements) == nil)
  }
}

struct PointAcceptanceTests {
  private func candidate(
    ref: Int? = 4, visible: Bool = true, fields: [String] = ["Save"]
  ) -> PointCandidate {
    PointCandidate(ref: ref, visible: visible, fields: fields)
  }

  @Test func aVisibleInteractiveElementThatMatchesIsAccepted() {
    #expect(PointAcceptance.evaluate("Click Save", candidate()) == .accepted(ref: 4))
  }

  @Test func aPointWithNoInteractiveElementUnderItIsRejected() {
    #expect(
      PointAcceptance.evaluate("Click Save", candidate(ref: nil)) == .rejected(.noInteractive))
  }

  @Test func aHiddenElementIsRejectedBeforeItsNameIsCompared() {
    #expect(
      PointAcceptance.evaluate("Click Save", candidate(visible: false)) == .rejected(.notVisible))
  }

  @Test func anInteractiveElementWithAnotherNameIsRejected() {
    #expect(
      PointAcceptance.evaluate("Click Save", candidate(fields: ["Cancel"])) == .rejected(.noMatch))
  }

  @Test func anyOfNameTextValuePlaceholderOrAriaLabelCanMatch() {
    let fields = ["", "", "", "Search the site", ""]
    #expect(
      PointAcceptance.evaluate("Click Search", candidate(fields: fields)) == .accepted(ref: 4))
  }

  @Test func theRejectionNamesItself() {
    #expect(PointRejection.noInteractive.reason == "point-rejected: no-interactive-element")
    #expect(PointRejection.notVisible.reason == "point-rejected: not-visible")
    #expect(PointRejection.noMatch.reason == "point-rejected: no-match")
  }
}

@MainActor
struct LadderTests {
  private var elements: [Element] { [element(1, "Save"), element(2, "Cancel")] }

  private final class Calls {
    var atom = 0
    var muse = 0
    var accepted: [Double] = []
  }

  /// `nil` is an absent rung; a point is one that answers; `.some(nil)` is one that abstains.
  private func resolve(
    _ instruction: String, _ calls: Calls, atom: (Double, Double)?? = .none,
    muse: (Double, Double)?? = .none,
    accept: @escaping Ladder.Accept = { _, _ in .accepted(ref: 9) }
  ) async -> LadderResult {
    let atomRung: Ladder.Ground? = atom.map { point in
      { @MainActor in
        calls.atom += 1
        return point.map { Point(x: $0.0, y: $0.1) }
      }
    }
    let museRung: Ladder.Ground? = muse.map { point in
      { @MainActor in
        calls.muse += 1
        return point.map { Point(x: $0.0, y: $0.1) }
      }
    }
    return await Ladder.resolve(
      instruction: instruction, elements: elements, atom: atomRung, muse: museRung, accept: accept)
  }

  @Test func aNameMatchResolvesByTheDomWithoutCallingAtomOrMuse() async {
    let calls = Calls()
    let result = await resolve("Click Save", calls, atom: (5, 5), muse: (6, 6))
    #expect(result == .resolved(ref: 1, rung: .dom))
    #expect(calls.atom == 0 && calls.muse == 0)
  }

  @Test func withoutADomMatchAtomResolvesAndMuseIsNotCalled() async {
    let calls = Calls()
    let result = await resolve("the sparkly icon", calls, atom: (5, 5), muse: (6, 6))
    #expect(result == .resolved(ref: 9, rung: .atom))
    #expect(calls.atom == 1 && calls.muse == 0)
  }

  @Test func anAbstainingAtomFallsThroughToMuse() async {
    let calls = Calls()
    let result = await resolve("the sparkly icon", calls, atom: .some(nil), muse: (6, 6))
    #expect(result == .resolved(ref: 9, rung: .muse))
    #expect(calls.atom == 1 && calls.muse == 1)
  }

  @Test func anAbsentAtomIsSkippedWithoutBeingCalled() async {
    let calls = Calls()
    let result = await resolve("the sparkly icon", calls, muse: (6, 6))
    #expect(result == .resolved(ref: 9, rung: .muse))
    #expect(calls.atom == 0 && calls.muse == 1)
  }

  @Test func aPointTheAcceptanceRefusesFallsThroughToTheNextRung() async {
    let calls = Calls()
    let result = await resolve(
      "the sparkly icon", calls, atom: (1, 1), muse: (2, 2),
      accept: { x, _ in
        calls.accepted.append(x)
        return x == 1 ? .rejected(.noMatch) : .accepted(ref: 7)
      })
    #expect(result == .resolved(ref: 7, rung: .muse))
    #expect(calls.accepted == [1, 2])
  }

  @Test func exhaustingTheLadderNeedsAHuman() async {
    let calls = Calls()
    let result = await resolve("the sparkly icon", calls, atom: .some(nil), muse: .some(nil))
    #expect(result == .needsHuman)
    #expect(calls.atom == 1 && calls.muse == 1)
  }

  @Test func withNoAtomAndNoMuseTheDomIsTheOnlyRung() async {
    let result = await resolve("the sparkly icon", Calls())
    #expect(result == .needsHuman)
  }
}

struct GroundingPolicyTests {
  @Test func underEightyPercentAtomClicksNeedApproval() {
    #expect(GroundingPolicy(hits: 15, samples: 20).atomNeedsApproval)
    #expect(GroundingPolicy(hits: 79, samples: 100).atomNeedsApproval)
  }

  @Test func atEightyPercentOrMoreTheNormalRulesApply() {
    #expect(!GroundingPolicy(hits: 16, samples: 20).atomNeedsApproval)
    #expect(!GroundingPolicy(hits: 20, samples: 20).atomNeedsApproval)
  }

  @Test func neverMeasuredIsNeverTrusted() {
    #expect(GroundingPolicy(hits: 0, samples: 0).atomNeedsApproval)
  }
}

struct PressKeyTests {
  @Test func namedKeysCarryTheirCodes() throws {
    let enter = try #require(PressKey.parse("Enter"))
    #expect(enter.key == "Enter" && enter.code == "Enter" && enter.keyCode == 13)
    #expect(enter.text == "\r")
    let down = try #require(PressKey.parse("ArrowDown"))
    #expect(down.keyCode == 40 && down.text == nil)
  }

  @Test func aSinglePrintableCharacterIsAKeyWithText() throws {
    let key = try #require(PressKey.parse("a"))
    #expect(key.key == "a" && key.code == "KeyA" && key.keyCode == 65 && key.text == "a")
  }

  @Test func unknownNamesAndChordsAreRefused() {
    #expect(PressKey.parse("Hyper") == nil)
    #expect(PressKey.parse("") == nil)
    #expect(PressKey.parse("Meta+Q") == nil)
  }
}
