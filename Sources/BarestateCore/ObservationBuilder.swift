import Foundation

/// The raw DevTools replies one observation is built from.
public struct RawObservation: Sendable {
  public let snapshot: JSON
  public let ax: JSON
  public let metrics: JSON
  public let frameTree: JSON
  public let dpr: Double

  public init(snapshot: JSON, ax: JSON, metrics: JSON, frameTree: JSON, dpr: Double) {
    self.snapshot = snapshot
    self.ax = ax
    self.metrics = metrics
    self.frameTree = frameTree
    self.dpr = dpr
  }
}

public enum ObservationError: Error, Equatable {
  case malformed(String)
  case unstable
}

extension Observation {
  /// Pure reduction of the five DevTools replies (architecture §5.2). Elements come from the
  /// accessibility tree, geometry and visibility from the DOM snapshot, in document order.
  public static func build(
    id: String, tabId: String, epoch: UInt64, raw: RawObservation
  )
    throws -> Observation
  {
    let dom = try DOMView(raw.snapshot)
    let keys = try PageKeys.parse(frameTree: raw.frameTree, metrics: raw.metrics, dpr: raw.dpr)
    let visual = raw.metrics["cssVisualViewport"]
    let scroll = (visual?["pageX"]?.number ?? 0, visual?["pageY"]?.number ?? 0)
    guard let axNodes = raw.ax["nodes"]?.array else {
      throw ObservationError.malformed("Accessibility.getFullAXTree: no nodes")
    }

    var found: [(node: Int, element: Element)] = []
    var seen = Set<Int>()
    for ax in axNodes where ax["ignored"]?.bool != true {
      guard let backend = ax["backendDOMNodeId"]?.int, let node = dom.index[backend],
        let role = ax["role"]?["value"]?.string
      else { continue }
      let name = ax["name"]?["value"]?.string ?? ""
      let isInteractiveRole = interactiveRoles.contains(role)
      guard isInteractiveRole || (!name.isEmpty && !textRoles.contains(role)) else { continue }
      let disabled = ax["properties"]?.array?.contains {
        $0["name"]?.string == "disabled" && $0["value"]?["value"]?.bool == true
      }
      found.append(
        (
          node,
          dom.element(
            node, role: role, name: name, value: scalarText(ax["value"]?["value"]),
            interactive: isInteractiveRole && disabled != true, scroll: scroll)
        ))
      seen.insert(backend)
    }
    // Controls the accessibility tree drops (display:none, visibility:hidden) still exist for
    // the agent to know about, but can never be acted on.
    for node in dom.fallbackCandidates where !seen.contains(dom.backendIds[node]) {
      found.append((node, dom.fallbackElement(node, scroll: scroll)))
    }
    found.sort { $0.node < $1.node }

    return Observation(
      id: id, tabId: tabId, epoch: epoch, documentKey: keys.documentKey,
      viewportKey: keys.viewportKey,
      url: raw.frameTree["frameTree"]?["frame"]?["url"]?.string ?? "",
      title: dom.title, elements: found.map(\.element))
  }

  private static let interactiveRoles: Set<String> = [
    "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox",
    "menuitem", "menuitemcheckbox", "menuitemradio", "option", "slider", "spinbutton", "switch",
    "tab", "treeitem", "PopUpButton", "DisclosureTriangle", "ColorWell",
  ]

  /// Roles that only restate text or wrap other nodes.
  private static let textRoles: Set<String> = [
    "StaticText", "InlineTextBox", "LineBreak", "LabelText", "ListMarker", "generic", "none",
    "presentation", "RootWebArea", "paragraph",
  ]

  private static func scalarText(_ json: JSON?) -> String? {
    switch json {
    case .string(let text)?: return text
    case .number(let number)?: return PageKeys.format(number)
    default: return nil
    }
  }
}

/// Flat arrays of a DOMSnapshot document, indexed by node.
private struct DOMView {
  private static let fallbackTags: Set<String> = ["button", "a", "input", "select", "textarea"]

  let strings: [String]
  /// The title of the document these arrays describe, so it can never come from another one.
  let title: String
  let backendIds: [Int]
  /// backendNodeId → node index.
  let index: [Int: Int]
  private let parents: [Int]
  private let nodeNames: [Int]
  private let nodeValues: [Int]
  private let attributes: [[Int]]
  private let rowOfNode: [Int: Int]
  private let bounds: [[Double]]
  private let styles: [[Int]]

  init(_ snapshot: JSON) throws {
    guard let strings = snapshot["strings"]?.array?.map({ $0.string ?? "" }),
      let document = snapshot["documents"]?[0], let nodes = document["nodes"],
      let layout = document["layout"],
      let backendIds = Self.ints(nodes["backendNodeId"]),
      let parents = Self.ints(nodes["parentIndex"]),
      let nodeNames = Self.ints(nodes["nodeName"]), let attributes = nodes["attributes"]?.array,
      let layoutNodes = Self.ints(layout["nodeIndex"]), let bounds = layout["bounds"]?.array,
      let styles = layout["styles"]?.array
    else { throw ObservationError.malformed("DOMSnapshot.captureSnapshot: unexpected shape") }
    self.strings = strings
    title =
      document["title"]?.int.flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
    self.backendIds = backendIds
    index = Dictionary(
      backendIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    self.parents = parents
    self.nodeNames = nodeNames
    nodeValues = Self.ints(nodes["nodeValue"]) ?? []
    self.attributes = attributes.map { Self.ints($0) ?? [] }
    rowOfNode = Dictionary(
      layoutNodes.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    self.bounds = bounds.map { $0.array?.compactMap(\.number) ?? [] }
    self.styles = styles.map { Self.ints($0) ?? [] }
  }

  private static func ints(_ json: JSON?) -> [Int]? {
    json?.array?.map { $0.int ?? -1 }
  }

  private func string(_ id: Int) -> String? {
    strings.indices.contains(id) ? strings[id] : nil
  }

  func tag(_ node: Int) -> String { (string(nodeNames[node]) ?? "").lowercased() }

  func attribute(_ node: Int, _ name: String) -> String? {
    let pairs = attributes[node]
    for position in stride(from: 0, to: pairs.count - 1, by: 2)
    where string(pairs[position]) == name {
      return string(pairs[position + 1])
    }
    return nil
  }

  var fallbackCandidates: [Int] {
    backendIds.indices.filter { node in
      let tag = tag(node)
      guard Self.fallbackTags.contains(tag) else { return false }
      if tag == "a" { return attribute(node, "href") != nil }
      return attribute(node, "type")?.lowercased() != "hidden"
    }
  }

  /// Viewport-relative bounds, or nil when the node generated no box.
  private func rect(_ node: Int, scroll: (Double, Double)) -> Rect? {
    guard let row = rowOfNode[node], bounds[row].count == 4 else { return nil }
    let box = bounds[row]
    return Rect(x: box[0] - scroll.0, y: box[1] - scroll.1, w: box[2], h: box[3])
  }

  /// Computed styles are requested as display, visibility, opacity, in that order.
  private func isVisible(_ node: Int, _ box: Rect?) -> Bool {
    guard let box, box.w > 0, box.h > 0, let row = rowOfNode[node], styles[row].count == 3 else {
      return false
    }
    let style = styles[row].map { string($0) ?? "" }
    return style[0] != "none" && style[1] == "visible" && (Double(style[2]) ?? 1) > 0
      && !hasTransparentAncestor(node)
  }

  /// Opacity is not inherited in computed style, but a transparent ancestor hides its subtree.
  private func hasTransparentAncestor(_ node: Int) -> Bool {
    var current = parents[node]
    while current >= 0 {
      if let row = rowOfNode[current], styles[row].count == 3,
        let opacity = Double(string(styles[row][2]) ?? ""), opacity <= 0
      {
        return true
      }
      current = parents[current]
    }
    return false
  }

  func element(
    _ node: Int, role: String, name: String, value: String?, interactive: Bool,
    scroll: (Double, Double)
  ) -> Element {
    let box = rect(node, scroll: scroll)
    return Element(
      ref: backendIds[node], role: role, name: name, value: value,
      bounds: box ?? Rect(x: 0, y: 0, w: 0, h: 0),
      interactive: interactive && isVisible(node, box), sensitive: isSensitive(node, name: name))
  }

  func fallbackElement(_ node: Int, scroll: (Double, Double)) -> Element {
    let type = attribute(node, "type")?.lowercased()
    let role: String
    switch tag(node) {
    case "a": role = "link"
    case "button": role = "button"
    case "select": role = "combobox"
    case "input" where type == "checkbox": role = "checkbox"
    case "input" where type == "radio": role = "radio"
    case "input" where ["button", "submit", "reset", "image"].contains(type ?? ""): role = "button"
    default: role = "textbox"
    }
    let name =
      attribute(node, "aria-label") ?? attribute(node, "title")
      ?? attribute(node, "placeholder") ?? attribute(node, "value") ?? ownText(node)
    return element(node, role: role, name: name, value: nil, interactive: false, scroll: scroll)
  }

  private func ownText(_ node: Int) -> String {
    backendIds.indices.filter { parents[$0] == node && tag($0) == "#text" }
      .compactMap { nodeValues.indices.contains($0) ? string(nodeValues[$0]) : nil }
      .joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isSensitive(_ node: Int, name: String) -> Bool {
    let tag = tag(node)
    let type = attribute(node, "type")?.lowercased()
    let isSubmit: Bool
    switch tag {
    case "button":
      // A missing or unknown type is a submit button, and the form may be named by `form=`.
      let defaultsToSubmit = !["reset", "button"].contains(type ?? "")
      isSubmit =
        type == "submit" || (defaultsToSubmit && (inForm(node) || attribute(node, "form") != nil))
    case "input": isSubmit = type == "submit" || type == "image"
    default: isSubmit = false
    }
    return Sensitivity.isSensitive(name: name, inputType: type, isSubmit: isSubmit)
  }

  private func inForm(_ node: Int) -> Bool {
    var current = parents[node]
    while current >= 0 {
      if tag(current) == "form" { return true }
      current = parents[current]
    }
    return false
  }
}
