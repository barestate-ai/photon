import AppKit
import BarestateCore
import CEFBridge

struct PendingPopup {
  let view: TabContentView
  let url: String
  let background: Bool
  let origin: NewTabOrigin
}

/// A page that asks for a new window gets a normal tab. CEF creates the popup browser inside a
/// tab view we hand it, so it stays in the opener's process and `window.opener` works.
@MainActor
extension AppController {
  func popupRequested(openerBrowserId: Int32, url: String, background: Bool) -> NSView? {
    guard !quitting, let opener = tab(browserId: openerBrowserId),
      let view = makeContentView(activate: !background)
    else { return nil }
    pendingPopups[ObjectIdentifier(view)] = PendingPopup(
      view: view, url: url, background: background,
      origin: canvas.origin(from: opener, .openedFrom))
    Log.info(
      .tabs,
      "popup opener=\(opener.id) background=\(background) origin=\(Log.origin(url))")
    return view
  }

  func linkOpenedInNewTab(openerBrowserId: Int32, url: String, background: Bool) {
    guard !quitting, let opener = tab(browserId: openerBrowserId) else { return }
    Log.info(
      .tabs, "link tab opener=\(opener.id) background=\(background) origin=\(Log.origin(url))")
    openTab(url: url, activate: !background, origin: canvas.origin(from: opener, .openedFrom))
  }

  func popupCreated(browserId: Int32, parent: NSView) {
    guard let pending = pendingPopups.removeValue(forKey: ObjectIdentifier(parent)) else { return }
    let tab = adopt(
      browserId: browserId, view: pending.view,
      url: pending.url.isEmpty ? "about:blank" : pending.url,
      title: "", activate: !pending.background, at: nil, origin: pending.origin)
    if quitting { closeTab(tab.id) }
  }

  func popupAborted(_ parent: NSView) {
    guard pendingPopups.removeValue(forKey: ObjectIdentifier(parent)) != nil else { return }
    parent.removeFromSuperview()
    Log.error(.tabs, "popup creation aborted")
  }

  /// Where a page opened from the page being looked at starts: with an edge from it. From the
  /// overview nothing is being looked at, so the new page starts alone.
  func focusedPageOrigin(_ kind: EdgeKind) -> NewTabOrigin {
    presentation == .focused ? canvas.origin(from: activeTab, kind) : .none
  }
}
