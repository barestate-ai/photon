import BarestateCore
import Testing

struct SensitivityTests {
  @Test func passwordInputsAreSensitive() {
    #expect(Sensitivity.isSensitive(name: "Password", inputType: "password", isSubmit: false))
  }

  @Test func submitControlsAreSensitive() {
    #expect(Sensitivity.isSensitive(name: "Continue", inputType: "submit", isSubmit: true))
  }

  @Test func moneyAndDestructiveWordsAreSensitive() {
    for name in [
      "Pay now", "Buy", "Place order", "Delete account", "Send", "Transfer funds", "Checkout",
    ] {
      #expect(Sensitivity.isSensitive(name: name, inputType: nil, isSubmit: false), "\(name)")
    }
  }

  @Test func enterInAFieldIsAsSensitiveAsTheSubmitItTriggers() {
    let field = LiveTarget(
      tag: "input", inputType: "text", isSubmit: false, words: "Account name",
      label: "Account name", submitsVia: "Delete account")
    let enter = PressKey.parse("Enter")
    #expect(field.isSensitive(pressing: enter))
    #expect(field.submitting(on: enter) == "Delete account")
    #expect(!field.isSensitive(pressing: PressKey.parse("a")))
    #expect(!field.isSensitive)
    let lone = LiveTarget(
      tag: "input", inputType: "text", isSubmit: false, words: "Search", label: "Search")
    #expect(!lone.isSensitive(pressing: enter))
  }

  @Test func twoControlsWithTheSameWordsAreNotTheSameTarget() {
    let first = LiveTarget(
      tag: "button", inputType: nil, isSubmit: false, words: "Delete item", label: "Delete item",
      node: 7)
    let second = LiveTarget(
      tag: "button", inputType: nil, isSubmit: false, words: "Delete item", label: "Delete item",
      node: 8)
    #expect(first != second)
  }

  @Test func aFrameOrClosedShadowHostIsSensitiveToAnyWriteThatCouldActivateIt() {
    let host = LiveTarget(
      tag: "iframe", inputType: nil, isSubmit: false, words: "", label: "", opaque: true)
    #expect(host.label == "an embedded frame")
    #expect(!host.isSensitive)
    // A click or typed text (no key) lands inside; so do Enter, Space and any key that enters text.
    for key in [nil, PressKey.parse("Enter"), PressKey.parse("Space")]
      + ["a", "Z", "7"].map(PressKey.parse)
    {
      #expect(host.isSensitive(pressing: key))
    }
    for name in ["ArrowDown", "Tab", "Escape", "Backspace", "Delete", "Home", "End", "PageUp"] {
      #expect(!host.isSensitive(pressing: PressKey.parse(name)), "\(name)")
    }
    let plain = LiveTarget(tag: "input", inputType: "text", isSubmit: false, words: "Q", label: "Q")
    #expect(!plain.isSensitive(pressing: PressKey.parse("a")))
    #expect(!plain.isSensitive(pressing: PressKey.parse("Space")))
    let titled = LiveTarget(
      tag: "iframe", inputType: nil, isSubmit: false, words: "Card form", label: "Card form",
      opaque: true)
    #expect(titled.label == "Card form")
  }

  @Test func theCardNamesKeysByNameNotByCharacter() {
    let names = ["Space", "Enter", "Tab", "Escape", "ArrowDown", "a"]
    #expect(names.map { PressKey.parse($0)?.name } == names)
  }

  @Test func ordinaryControlsAreNot() {
    for name in ["Go", "More details", "Search", "Border style", "Reorder"] {
      #expect(!Sensitivity.isSensitive(name: name, inputType: nil, isSubmit: false), "\(name)")
    }
    #expect(!Sensitivity.isSensitive(name: "Full name", inputType: "text", isSubmit: false))
  }
}
