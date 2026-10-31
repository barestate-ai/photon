import BarestateCore

/// The one list of tabs. The horizontal strip, the shortcuts and the socket all read and change it
/// here, so they cannot disagree about order or which tab is active.
@MainActor
final class TabStore {
  private(set) var order = TabOrder()
  private(set) var closed = ClosedTabs()
  private var byId: [String: Tab] = [:]

  /// Called after every change that a presentation shows (order, active tab, title, address).
  var onChange: (() -> Void)?

  var tabs: [Tab] { order.ids.compactMap { byId[$0] } }
  var activeId: String? { order.active }
  var active: Tab? { activeId.flatMap { byId[$0] } }

  func tab(id: String) -> Tab? { byId[id] }

  func add(_ tab: Tab, at index: Int? = nil, activate: Bool) {
    byId[tab.id] = tab
    if let index {
      order.insert(tab.id, at: index, activate: activate)
    } else {
      order.append(tab.id, activate: activate)
    }
    onChange?()
  }

  func activate(_ id: String) {
    order.activate(id)
    onChange?()
  }

  func move(_ id: String, to index: Int) {
    order.move(id, to: index)
    onChange?()
  }

  /// A tab a person closed can come back with ⌘⇧T; one the page or the app closed cannot.
  @discardableResult
  func remove(_ tab: Tab, remember: Bool) -> Int? {
    guard let index = order.remove(tab.id) else { return nil }
    byId[tab.id] = nil
    if remember {
      closed.push(ClosedTabs.Entry(url: tab.url, title: tab.title, index: index))
    }
    onChange?()
    return index
  }

  func popClosed() -> ClosedTabs.Entry? { closed.pop() }
}
