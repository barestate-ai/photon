import Foundation

/// The keys `press` can send: a named key or one printable character, no chords.
public struct PressKey: Sendable, Equatable {
  public let key: String
  public let code: String
  public let keyCode: Int
  public let text: String?

  /// What a person would call the key; a space is invisible in quotes.
  public var name: String { key == " " ? "Space" : key }

  private static let named: [String: PressKey] = [
    "Enter": PressKey(key: "Enter", code: "Enter", keyCode: 13, text: "\r"),
    "Tab": PressKey(key: "Tab", code: "Tab", keyCode: 9, text: nil),
    "Escape": PressKey(key: "Escape", code: "Escape", keyCode: 27, text: nil),
    "Backspace": PressKey(key: "Backspace", code: "Backspace", keyCode: 8, text: nil),
    "Delete": PressKey(key: "Delete", code: "Delete", keyCode: 46, text: nil),
    "Space": PressKey(key: " ", code: "Space", keyCode: 32, text: " "),
    "ArrowLeft": PressKey(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, text: nil),
    "ArrowUp": PressKey(key: "ArrowUp", code: "ArrowUp", keyCode: 38, text: nil),
    "ArrowRight": PressKey(key: "ArrowRight", code: "ArrowRight", keyCode: 39, text: nil),
    "ArrowDown": PressKey(key: "ArrowDown", code: "ArrowDown", keyCode: 40, text: nil),
    "Home": PressKey(key: "Home", code: "Home", keyCode: 36, text: nil),
    "End": PressKey(key: "End", code: "End", keyCode: 35, text: nil),
    "PageUp": PressKey(key: "PageUp", code: "PageUp", keyCode: 33, text: nil),
    "PageDown": PressKey(key: "PageDown", code: "PageDown", keyCode: 34, text: nil),
  ]

  public static func parse(_ name: String) -> PressKey? {
    if let key = named[name] { return key }
    guard name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII,
      let ascii = Optional(Character(scalar)), ascii.isLetter || ascii.isNumber
    else { return nil }
    let upper = name.uppercased()
    let code = ascii.isLetter ? "Key\(upper)" : "Digit\(name)"
    return PressKey(
      key: name, code: code, keyCode: Int(upper.unicodeScalars.first!.value), text: name)
  }
}
