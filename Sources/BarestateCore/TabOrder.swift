/// The order of the tabs and which one is active. Both tab presentations read this and nothing
/// else decides order, so a shortcut and a click always agree.
public struct TabOrder: Equatable, Sendable {
  public private(set) var ids: [String] = []
  public private(set) var active: String?
  private var used: [String] = []

  public init() {}

  /// Tabs by last use, newest first. A tab nobody has shown yet follows the used ones in tab order.
  public var recency: [String] { used + ids.filter { !used.contains($0) } }

  public mutating func append(_ id: String, activate: Bool) {
    ids.append(id)
    if activate || active == nil { select(id) }
  }

  public mutating func insert(_ id: String, at index: Int, activate: Bool) {
    ids.insert(id, at: min(max(index, 0), ids.count))
    if activate || active == nil { select(id) }
  }

  public mutating func activate(_ id: String) {
    if ids.contains(id) { select(id) }
  }

  private mutating func select(_ id: String) {
    active = id
    used.removeAll { $0 == id }
    used.insert(id, at: 0)
  }

  /// Returns the index the tab had. Closing the active tab selects the tab that takes its place,
  /// or the last one when it was last.
  @discardableResult
  public mutating func remove(_ id: String) -> Int? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    ids.remove(at: index)
    used.removeAll { $0 == id }
    if active == id {
      active = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
      if let active { select(active) }
    }
    return index
  }

  public mutating func move(_ id: String, to index: Int) {
    guard let from = ids.firstIndex(of: id) else { return }
    ids.remove(at: from)
    ids.insert(id, at: min(max(index, 0), ids.count))
  }

  /// The tab `step` places after the active one, wrapping at both ends.
  public func cycled(by step: Int) -> String? {
    guard let active, let index = ids.firstIndex(of: active) else { return nil }
    let count = ids.count
    return ids[((index + step) % count + count) % count]
  }

  /// ⌘1 to ⌘8 pick that position when it exists; ⌘9 always picks the last tab.
  public func shortcutTarget(_ number: Int) -> String? {
    if number == 9 { return ids.last }
    return (1...8).contains(number) && number <= ids.count ? ids[number - 1] : nil
  }
}

/// Tabs closed by a person, newest last, for ⌘⇧T.
public struct ClosedTabs: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let url: String
    public let title: String
    public let index: Int

    public init(url: String, title: String, index: Int) {
      self.url = url
      self.title = title
      self.index = index
    }
  }

  private var entries: [Entry] = []
  private let limit: Int

  public init(limit: Int = 25) {
    self.limit = limit
  }

  public mutating func push(_ entry: Entry) {
    entries.append(entry)
    if entries.count > limit { entries.removeFirst() }
  }

  public mutating func pop() -> Entry? {
    entries.popLast()
  }

  public var isEmpty: Bool { entries.isEmpty }
}
