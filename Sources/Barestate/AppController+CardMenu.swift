import AppKit
import BarestateCore
import CEFBridge

/// The right-click menu of a card: Open, Maximize and Close Page, each doing exactly what its
/// button, click or shortcut does for that page.
@MainActor
extension AppController {
  func showCardMenu(for id: String, at point: CGPoint) {
    guard let root, let node = canvas.graph.nodes.first(where: { $0.id == id }) else { return }
    let live = node.tabId.map { tab(id: $0) != nil } ?? false
    root.cardMenu.show(for: id, live: live, at: point)
  }

  func perform(_ action: CardAction, on id: String) {
    switch action {
    case .open: focusNode(id)
    case .maximize: maximize(node: id)
    case .closePage:
      if let tabId = canvas.graph.nodes.first(where: { $0.id == id })?.tabId, tab(id: tabId) != nil
      {
        closeByPerson(tabId)
      }
      returnKeyboard()
    }
  }

  /// A menu closed with nothing chosen hands the keyboard back to where it was.
  func returnKeyboard() {
    if presentation == .focused, let tab = activeTab {
      BSCef.focusBrowser(tab.browserId)
    } else {
      window?.makeFirstResponder(root)
    }
  }
}
