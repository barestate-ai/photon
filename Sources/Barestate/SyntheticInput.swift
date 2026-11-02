import AppKit
import BarestateCore

/// Builds the NSEvents the test hooks post. They enter through `NSApp.postEvent`, never as
/// CGEvents, so the real cursor does not move.
@MainActor
enum SyntheticInput {
  struct Stroke {
    let keyCode: UInt16
    let characters: String
  }

  /// US ANSI virtual key codes.
  private static let codes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
  ]

  private static let named: [String: Stroke] = [
    "Return": Stroke(keyCode: 36, characters: "\r"),
    "Enter": Stroke(keyCode: 36, characters: "\r"),
    "Tab": Stroke(keyCode: 48, characters: "\t"),
    "Space": Stroke(keyCode: 49, characters: " "),
    "Backspace": Stroke(keyCode: 51, characters: "\u{7f}"),
    "Escape": Stroke(keyCode: 53, characters: "\u{1b}"),
    "ArrowLeft": Stroke(keyCode: 123, characters: "\u{f702}"),
    "ArrowRight": Stroke(keyCode: 124, characters: "\u{f703}"),
    "ArrowDown": Stroke(keyCode: 125, characters: "\u{f701}"),
    "ArrowUp": Stroke(keyCode: 126, characters: "\u{f700}"),
  ]

  /// Characters typed with Shift on a US keyboard, mapped to the unshifted key that produces them.
  private static let shifted: [Character: Character] = [
    ":": ";", "?": "/", "+": "=", "_": "-", "\"": "'", "<": ",", ">": ".", "{": "[", "}": "]",
    "|": "\\", "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0",
  ]

  static let modifierFlags: [String: NSEvent.ModifierFlags] = [
    "cmd": .command, "shift": .shift, "ctrl": .control, "alt": .option,
  ]

  private static var lastTick: Int64 = 0

  /// Each posted event gets its own timestamp: `BarestateApplication.post` uses it to know
  /// when the event has gone through `sendEvent`.
  private static func nextStamp() -> TimeInterval {
    lastTick = max(lastTick + 1, EventStamp.tick(ProcessInfo.processInfo.systemUptime))
    return EventStamp.time(ofTick: lastTick)
  }

  static func stroke(for key: String) -> Stroke? {
    if let stroke = named[key] { return stroke }
    guard key.count == 1, let character = key.lowercased().first else { return nil }
    return Stroke(keyCode: codes[character] ?? 0, characters: key)
  }

  /// `repeats` extra auto-repeat key-downs follow the first; `releaseModifiersFirst` sends the
  /// key-up with the modifiers already let go, as happens when the fingers lift in that order.
  /// `press` and `release` left off split a long press into the parts a test sends apart.
  static func keyEvents(
    _ stroke: Stroke, modifiers: NSEvent.ModifierFlags, windowNumber: Int, repeats: Int = 0,
    releaseModifiersFirst: Bool = false, press: Bool = true, release: Bool = true
  ) -> [NSEvent] {
    // A keyboard reports Shift-Tab as the back-tab character.
    var characters = stroke.characters
    if modifiers.contains(.shift) {
      characters = stroke.keyCode == 48 ? "\u{19}" : characters.uppercased()
    }
    let phases: [(NSEvent.EventType, Bool)] =
      (press ? [(.keyDown, false)] : []) + Array(repeating: (.keyDown, true), count: repeats)
      + (release ? [(.keyUp, false)] : [])
    return phases.compactMap { type, isRepeat in
      let flags = type == .keyUp && releaseModifiersFirst ? [] : modifiers
      return NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: nextStamp(),
        windowNumber: windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters.lowercased(), isARepeat: isRepeat,
        keyCode: stroke.keyCode)
    }
  }

  /// Uppercase letters go out as shift plus the lowercase key, as a keyboard sends them.
  static func typeEvents(_ text: String, windowNumber: Int) -> [NSEvent] {
    text.flatMap { character -> [NSEvent] in
      let base = shifted[character] ?? Character(character.lowercased())
      let needsShift = character.isUppercase || shifted[character] != nil
      return keyEvents(
        Stroke(keyCode: codes[base] ?? 0, characters: String(character)),
        modifiers: needsShift ? .shift : [], windowNumber: windowNumber)
    }
  }

  /// `point` is in window coordinates (origin bottom-left). `count` presses in a row, the nth
  /// carrying click count n, as a double-click does. `right` presses the secondary button.
  static func clickEvents(
    at point: NSPoint, windowNumber: Int, modifiers: NSEvent.ModifierFlags = [], count: Int = 1,
    right: Bool = false
  ) -> [NSEvent] {
    var steps: [(NSEvent.EventType, Float, Int)] = [(.mouseMoved, 0, 0)]
    for press in 1...max(1, count) {
      steps += [
        (right ? .rightMouseDown : .leftMouseDown, 1, press),
        (right ? .rightMouseUp : .leftMouseUp, 0, press),
      ]
    }
    return steps.compactMap { type, pressure, clicks in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: modifiers, timestamp: nextStamp(),
        windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
        pressure: pressure)
    }
  }

  static func moveEvent(to point: NSPoint, windowNumber: Int) -> [NSEvent] {
    NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [], timestamp: nextStamp(),
      windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ).map { [$0] } ?? []
  }

  /// Press at `start`, drag to `end` in `steps` moves, and release there unless `release` is
  /// false.
  static func dragEvents(
    from start: NSPoint, to end: NSPoint, windowNumber: Int, release: Bool, steps count: Int = 1
  ) -> [NSEvent] {
    var steps: [(NSEvent.EventType, NSPoint, Float)] = [
      (.mouseMoved, start, 0), (.leftMouseDown, start, 1),
    ]
    let moves = max(1, count)
    for move in 1...moves {
      let fraction = Double(move) / Double(moves)
      let point = NSPoint(
        x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
      steps.append((.leftMouseDragged, point, 1))
    }
    if release { steps.append((.leftMouseUp, end, 0)) }
    return steps.compactMap { type, point, pressure in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: nextStamp(),
        windowNumber: windowNumber, context: nil, eventNumber: 0,
        clickCount: type == .mouseMoved ? 0 : 1, pressure: pressure)
    }
  }

  static func releaseEvent(at point: NSPoint, windowNumber: Int) -> [NSEvent] {
    NSEvent.mouseEvent(
      with: .leftMouseUp, location: point, modifierFlags: [], timestamp: nextStamp(),
      windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
    ).map { [$0] } ?? []
  }
}
