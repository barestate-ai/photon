import Foundation

public struct Rect: Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let w: Double
  public let h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }

  public var json: JSON { ["x": .number(x), "y": .number(y), "w": .number(w), "h": .number(h)] }
}

public struct Element: Sendable, Equatable {
  /// The DOM backendNodeId: stable for the life of the document, usable in later CDP calls.
  public let ref: Int
  public let role: String
  public let name: String
  public let value: String?
  /// CSS pixels relative to the viewport's top-left at the time of the observation.
  public let bounds: Rect
  public let interactive: Bool
  public let sensitive: Bool

  public init(
    ref: Int, role: String, name: String, value: String? = nil, bounds: Rect, interactive: Bool,
    sensitive: Bool
  ) {
    self.ref = ref
    self.role = role
    self.name = name
    self.value = value
    self.bounds = bounds
    self.interactive = interactive
    self.sensitive = sensitive
  }

  public var json: JSON {
    var fields: [String: JSON] = [
      "ref": .number(Double(ref)), "role": .string(role), "name": .string(name),
      "bounds": bounds.json, "interactive": .bool(interactive), "sensitive": .bool(sensitive),
    ]
    if let value { fields["value"] = .string(value) }
    return .object(fields)
  }
}

/// What the page looked like at one instant. The two keys say whether it still looks that way:
/// `documentKey` changes with every new document, `viewportKey` with scroll, size and scale.
public struct Observation: Sendable, Equatable {
  public let id: String
  public let tabId: String
  public let epoch: UInt64
  public let documentKey: String
  public let viewportKey: String
  public let url: String
  public let title: String
  public let elements: [Element]

  public init(
    id: String, tabId: String, epoch: UInt64, documentKey: String, viewportKey: String,
    url: String, title: String, elements: [Element]
  ) {
    self.id = id
    self.tabId = tabId
    self.epoch = epoch
    self.documentKey = documentKey
    self.viewportKey = viewportKey
    self.url = url
    self.title = title
    self.elements = elements
  }

  public var json: JSON {
    [
      "id": .string(id), "tabId": .string(tabId), "epoch": .number(Double(epoch)),
      "documentKey": .string(documentKey), "viewportKey": .string(viewportKey),
      "url": .string(url), "title": .string(title), "elements": .array(elements.map(\.json)),
    ]
  }
}
