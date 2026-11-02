import AppKit
import BarestateCore

/// State dumps and view lookup for the Maximize controls and the card menu. Frames are window
/// points from the top left.
@MainActor
extension AppController {
  private func maximizeControls() -> [(where: String, button: MaximizeButton)] {
    let overview = (root?.canvasView?.maximize.shown ?? []).map { ("overview", $0) }
    let focus = (root?.focusContext?.maximize.shown ?? []).map { ("focus", $0) }
    return overview + focus
  }

  /// `test.ui.maximize`: every Maximize control a person can see now.
  func maximizeState() -> JSON {
    guard let root else { return .null }
    let content = root.convert(root.bounds, to: nil)
    return .array(
      maximizeControls().map { place, button in
        let shown = button.convert(button.bounds, to: nil).intersection(content)
        return [
          "node": .string(button.node), "where": .string(place),
          "label": .string(button.accessibilityLabel() ?? ""),
          "area": .number(shown.isNull ? 0 : Double(shown.width * shown.height)),
          "frame": windowRect(button),
        ]
      })
  }

  func maximizeView(_ node: String) -> NSView? {
    maximizeControls().first { $0.button.node == node }?.button
  }

  /// `test.ui.cardMenu`: whether the card menu is open, for which card, and what it offers.
  func cardMenuState() -> JSON {
    guard let menu = root?.cardMenu else { return .null }
    return [
      "open": .bool(menu.isOpen), "node": menu.node.map { .string($0) } ?? .null,
      "frame": menu.isOpen ? windowRect(menu.panel) : json(.zero),
      "items": .array(
        menu.items.map {
          ["title": .string($0.title), "enabled": .bool($0.enabled), "frame": windowRect($0.view)]
        }),
    ]
  }

  func cardMenuView(_ title: String) -> NSView? {
    root?.cardMenu.items.first { $0.title == title }?.view
  }
}
