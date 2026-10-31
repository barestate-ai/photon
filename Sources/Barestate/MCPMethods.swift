import BarestateCore
import CEFBridge

/// The MCP methods on the socket. stdio (`barestate-mcp`) and the gateway forward to these, so one
/// dispatcher serves every transport. Tools run the socket methods of the same name; the shared
/// Approvals registry decides control and sensitive acts.
@MainActor
func registerMCPMethods(_ dispatcher: RPCDispatcher, controller: AppController) {
  let server = MCPServer(version: AppController.version) { tool, arguments in
    tool == "open_tab"
      ? try await controller.openTabForSession(arguments)
      : try await dispatcher.call(tool, arguments)
  }
  for method in MCPServer.methods {
    dispatcher.register(method) { params in
      do {
        let result = try await server.handle(method, params)
        log(method, params, result)
        return result
      } catch {
        Log.error(.remote, "mcp \(method) failed: \(Log.describe(error))")
        throw error
      }
    }
  }

  /// Names and verdicts only: no arguments, results or page content.
  func log(_ method: String, _ params: JSON, _ result: JSON) {
    switch method {
    case "initialize":
      let client = params["clientInfo"]
      Log.info(
        .remote,
        "mcp initialize client=\(client?["name"]?.string?.prefix(40) ?? "?") "
          + "version=\(client?["version"]?.string?.prefix(20) ?? "?") "
          + "protocol=\(params["protocolVersion"]?.string?.prefix(12) ?? "?")")
    case "tools/call":
      Log.info(
        .remote,
        "mcp tool=\(params["name"]?.string?.prefix(40) ?? "?") "
          + "session=\(params["_meta"]?[MCPServer.sessionKey]?.string?.prefix(40) ?? "?") "
          + "error=\(result["isError"] == true)")
    default: break
    }
  }
}

@MainActor
extension AppController {
  /// `open_tab` for an outside agent. A new tab is the session's own (control is granted when it
  /// opens); an existing tab is navigated only if the session already controls it. Only web
  /// addresses, so a client cannot reach `file:` or `javascript:` through the person's browser.
  func openTabForSession(_ arguments: JSON) async throws -> JSON {
    let session = try arguments.requireString("sessionId")
    let url = try arguments.requireString("url")
    guard Dispatch.isWebAddress(url) else {
      throw RPCError.failure("only http and https addresses can be opened")
    }
    if arguments["tabId"] != nil {
      let tab = try resolveTab(arguments)
      guard tab.control.controller == .agent(session) else {
        throw RPCError.failure("not-in-control: ask the person with request_control first")
      }
      BSCef.loadURL(url, inBrowser: tab.browserId)
      return describe(tab)
    }
    guard let tab = openTab(url: url) else {
      throw RPCError.failure("the browser could not open a tab")
    }
    tab.control.grant(session: session)
    for _ in 0..<150 where tab.loading { try? await Task.sleep(for: .milliseconds(100)) }
    return describe(tab)
  }
}
