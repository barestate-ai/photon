import Foundation

public struct Point: Sendable, Equatable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// Which part of the ladder found the element (architecture §5.4); recorded on the journal row.
public enum Rung: String, Sendable {
  case ref, point, dom, atom, muse
}

/// Token overlap between an instruction and the words an element shows.
public enum InstructionMatch {
  private static let filler: Set<String> = [
    "a", "an", "the", "click", "tap", "press", "select", "choose", "pick", "on", "at", "in", "into",
    "to", "of", "for", "and", "then", "please", "this", "that", "with", "my", "it", "its", "button",
    "link", "field", "input", "box", "checkbox", "option", "icon", "text", "tab", "menu", "item",
  ]

  public static func tokens(_ text: String) -> Set<String> {
    Set(
      text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter {
        !filler.contains($0)
      })
  }

  /// The share of the instruction's content words that appear in `field`; 0 when it has none.
  static func score(_ wanted: Set<String>, in field: String) -> Double {
    guard !wanted.isEmpty else { return 0 }
    return Double(wanted.intersection(tokens(field)).count) / Double(wanted.count)
  }

  static let threshold = 0.5

  public static func matches(_ instruction: String, fields: [String]) -> Bool {
    let wanted = tokens(instruction)
    return fields.contains { score(wanted, in: $0) >= threshold }
  }

  /// The one interactive element whose name or value covers the instruction best, preferring the
  /// tighter name; nil when none matches or the best is a tie between different elements.
  public static func best(instruction: String, in elements: [Element]) -> Element? {
    let wanted = tokens(instruction)
    var ranked: [(element: Element, score: Double, size: Int)] = []
    for element in elements where element.interactive {
      let fields = [element.name, element.value ?? ""]
      let score = fields.map { Self.score(wanted, in: $0) }.max() ?? 0
      if score >= threshold { ranked.append((element, score, tokens(element.name).count)) }
    }
    guard
      let top = ranked.max(by: { ($0.score, -$0.size) < ($1.score, -$1.size) })
    else { return nil }
    let tied = ranked.filter { $0.score == top.score && $0.size == top.size }
    return tied.count == 1 ? top.element : nil
  }
}

/// What lies under a candidate point: its nearest interactive ancestor, if any, and the words that
/// element shows.
public struct PointCandidate: Sendable, Equatable {
  public let ref: Int?
  public let visible: Bool
  public let fields: [String]

  public init(ref: Int?, visible: Bool, fields: [String]) {
    self.ref = ref
    self.visible = visible
    self.fields = fields
  }
}

public enum PointRejection: String, Sendable, Equatable {
  case noInteractive = "no-interactive-element"
  case notVisible = "not-visible"
  case noMatch = "no-match"

  /// What the journal row says.
  public var reason: String { "point-rejected: \(rawValue)" }
}

public enum PointVerdict: Sendable, Equatable {
  case accepted(ref: Int)
  case rejected(PointRejection)
}

/// A grounded point becomes a click only if an interactive, visible element named like the
/// instruction is under it (architecture §5.4).
public enum PointAcceptance {
  public static func evaluate(_ instruction: String, _ candidate: PointCandidate) -> PointVerdict {
    guard let ref = candidate.ref else { return .rejected(.noInteractive) }
    guard candidate.visible else { return .rejected(.notVisible) }
    guard InstructionMatch.matches(instruction, fields: candidate.fields) else {
      return .rejected(.noMatch)
    }
    return .accepted(ref: ref)
  }
}

public enum LadderResult: Sendable, Equatable {
  case resolved(ref: Int, rung: Rung)
  case needsHuman
}

/// DOM, then Atom, then Muse; each later rung runs only when the earlier ones found nothing.
public enum Ladder {
  public typealias Ground = @MainActor () async -> Point?
  public typealias Accept = @MainActor (Double, Double) async -> PointVerdict

  @MainActor
  public static func resolve(
    instruction: String, elements: [Element], atom: Ground?, muse: Ground?, accept: Accept
  ) async -> LadderResult {
    if let element = InstructionMatch.best(instruction: instruction, in: elements) {
      return .resolved(ref: element.ref, rung: .dom)
    }
    for (rung, ground) in [(Rung.atom, atom), (Rung.muse, muse)] {
      guard let ground, let point = await ground() else { continue }
      if case .accepted(let ref) = await accept(point.x, point.y) {
        return .resolved(ref: ref, rung: rung)
      }
    }
    return .needsHuman
  }
}

/// FT4 (architecture §9): under 80% verified hits, a click Atom grounded needs a human.
public struct GroundingPolicy: Sendable, Equatable {
  public static let threshold = 0.8

  /// The rate measured on the fixture targets (D40 in DECISIONS.md; `e2e/test_act_kinds.py` keeps
  /// the two equal). Unmeasured would count as under the bar.
  public static let measured = GroundingPolicy(hits: 24, samples: 24)

  public let hits: Int
  public let samples: Int

  public init(hits: Int, samples: Int) {
    self.hits = hits
    self.samples = samples
  }

  public var rate: Double { samples == 0 ? 0 : Double(hits) / Double(samples) }
  public var atomNeedsApproval: Bool { rate < Self.threshold }
}
