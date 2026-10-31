import AppKit
import BarestateCore

@MainActor
extension AppController {
  func controlState(_ tab: Tab) -> [String: JSON] {
    var fields: [String: JSON] = [
      "tabId": .string(tab.id), "epoch": .number(Double(tab.control.epoch)),
      "controller": .string("human"),
    ]
    if case .agent(let session) = tab.control.controller {
      fields["controller"] = .string("agent")
      fields["controllerSession"] = .string(session)
    }
    return fields
  }

  /// A human's answer, from the card or the socket. A replay of an answered action approval gets
  /// the same answer again and does nothing.
  func decideApproval(_ id: String, allow: Bool) throws -> JSON {
    guard let item = approvals.item(id) else {
      if let earlier = approvals.answer(for: id) { return earlier }
      throw RPCError.failure("no pending approval \(id)")
    }
    switch item.subject {
    case .action:
      approvals.resolve(id, allow ? .allow : .deny)
      return approvals.answer(for: id) ?? [:]
    case .control:
      guard let tab = tab(id: item.tabId) else { throw RPCError.failure("the tab was closed") }
      approvals.resolve(id, allow ? .allow : .deny)
      if allow { tab.control.grant(session: item.sessionId) }
      var fields = controlState(tab)
      fields["requestId"] = .string(id)
      fields["approvalId"] = .string(id)
      fields["state"] = allow ? "granted" : "denied"
      return .object(fields)
    }
  }

  /// Whether Tab on this page can leave its pending approvals as they are: it only walks to the
  /// card, unless an approval is for whatever has the focus, which Tab would change.
  func approvalsSurviveTab(on tabId: String) -> Bool {
    let pending = approvals.items.filter { $0.tabId == tabId }
    return !pending.isEmpty && !pending.contains { $0.tracksFocus }
  }

  func reapApprovals() {
    approvals.reap { [unowned self] in tab(id: $0) }
  }

  /// Shows the oldest pending approval of the page in view (any page in the overview), or none.
  func refreshApproval(animated: Bool = true) {
    guard let root else { return }
    activity.refresh()
    let focused = presentation == .focused
    let item = approvals.items.first { !focused || $0.tabId == activeTabId }
    guard let item, !launcher.isOpen else {
      root.setApproval(nil, animated: animated && !launcher.isOpen, quickly: approvals.lastWasStale)
      return
    }
    root.setApproval(
      .init(item: item, focused: focused, nodeId: canvas.graph.nodeId(forTab: item.tabId)),
      animated: animated)
  }
}

// MARK: Test state

extension AppController {
  func approvalState() -> JSON {
    guard let root else { return .null }
    let card = root.approvalCard
    var fields: [String: JSON] = [
      "pending": .array(approvals.items.map(Approvals.json)),
      "visible": .bool(!card.isHiddenOrHasHiddenAncestor), "decided": .bool(card.decided),
    ]
    guard !card.isHidden, let item = card.item else { return .object(fields) }
    func hittable(_ view: NSView) -> Bool {
      guard let window, !view.isHiddenOrHasHiddenAncestor else { return false }
      let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
      return window.contentView?.superview?.hitTest(point) === view
    }
    func button(_ view: ApprovalButton) -> JSON {
      [
        "frame": windowRect(view), "label": .string(view.accessibilityLabel() ?? ""),
        "enabled": .bool(view.isEnabled), "hittable": .bool(hittable(view)),
        "focused": .bool(window?.firstResponder === view),
        "font": .string(view.labelFont?.fontName ?? ""),
      ]
    }
    let page = root.pageRect
    fields["id"] = .string(item.id)
    fields["text"] = .string(card.quoteText)
    fields["frame"] = windowRect(card)
    fields["font"] = .string(card.quoteFont?.fontName ?? "")
    fields["allow"] = button(card.allow)
    fields["deny"] = button(card.deny)
    fields["fits"] = .bool(card.labelsFit)
    fields["insideWindow"] = .bool(root.bounds.contains(card.frame))
    fields["focusedPresentation"] = .bool(presentation == .focused)
    fields["pageFrame"] = json(page)
    fields["overlapsPage"] = .bool(presentation == .focused && card.frame.intersects(page))
    return .object(fields)
  }
}
