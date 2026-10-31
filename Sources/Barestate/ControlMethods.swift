import BarestateCore

/// The socket side of the approval list. The Mac card and these methods decide the same items.
@MainActor
func registerControlMethods(_ dispatcher: RPCDispatcher, controller: AppController) {
  let approvals = controller.approvals

  func decide(_ params: JSON, key: String) throws -> JSON {
    let id = try params.requireString(key)
    if let session = params["remoteSession"]?.string, !controller.events.isOpen(session) {
      throw RPCError.failure("no-session")
    }
    guard let allow = params["allow"]?.bool else {
      throw RPCError.invalidParams("allow (bool) required")
    }
    return try controller.decideApproval(id, allow: allow)
  }

  dispatcher.register("request_control") { params in
    let session = try params.requireString("sessionId")
    let tab = try controller.resolveTab(params)
    var fields = controller.controlState(tab)
    if tab.control.controller == .agent(session) {
      fields["state"] = "granted"
    } else {
      fields["state"] = "pending"
      let page = tab.title.isEmpty ? tab.url : tab.title
      let id = approvals.openControl(
        tabId: tab.id, sessionId: session, text: "Let \(session) control \"\(page)\"",
        epoch: tab.control.epoch)
      fields["requestId"] = .string(id)
      fields["approvalId"] = .string(id)
    }
    return .object(fields)
  }

  dispatcher.register("approval.list") { _ in
    ["approvals": .array(approvals.items.map(Approvals.json))]
  }
  dispatcher.register("approval.decide") { try decide($0, key: "approvalId") }
  dispatcher.register("control.decide") { try decide($0, key: "requestId") }

  dispatcher.register("handoff") { params in
    let session = try params.requireString("sessionId")
    let tab = try controller.resolveTab(params)
    if case .agent(let holder) = tab.control.controller, holder != session {
      throw RPCError.failure("another session is in control of this tab")
    }
    tab.control.handoff()
    return .object(controller.controlState(tab))
  }
}
