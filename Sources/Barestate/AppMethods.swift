import AppKit
import BarestateCore

extension RPCError {
  static func failure(_ message: String) -> RPCError { RPCError(code: -32000, message: message) }

  init(_ error: CDPError) {
    switch error {
    case .timeout: self = .failure("DevTools call timed out after 10 s")
    case .closed: self = .failure("the tab was closed")
    case .sendFailed: self = .failure("the tab did not accept the DevTools message")
    case .remote(let code, let message): self = .failure("DevTools error \(code): \(message)")
    }
  }
}

extension JSON {
  func requireString(_ key: String) throws -> String {
    guard let value = self[key]?.string else {
      throw RPCError.invalidParams("\(key) (string) required")
    }
    return value
  }
}

@MainActor
extension AppController {
  /// The tab named by `tabId`, else the active one.
  func resolveTab(_ params: JSON) throws -> Tab {
    if let id = params["tabId"]?.string {
      guard let tab = tab(id: id) else { throw RPCError.failure("unknown tab \(id)") }
      return tab
    }
    guard let tab = activeTab else { throw RPCError.failure("no tab is open") }
    return tab
  }

  func describe(_ tab: Tab) -> JSON {
    [
      "id": .string(tab.id), "url": .string(tab.url), "title": .string(tab.title),
      "loading": .bool(tab.loading), "active": .bool(tab.id == activeTabId),
    ]
  }
}

@MainActor
func registerAppMethods(_ dispatcher: RPCDispatcher, controller: AppController) {
  dispatcher.register("app.status") { _ in
    [
      "version": .string(AppController.version),
      "ready": .bool(controller.ready),
      "tabs": .number(Double(controller.tabs.count)),
      "dataDir": .string(controller.dataDir.root),
    ]
  }

  dispatcher.register("tabs") { _ in
    ["tabs": .array(controller.tabs.map(controller.describe))]
  }

  dispatcher.register("open_tab") { params in
    let url = try params.requireString("url")
    guard let tab = controller.openTab(url: url, activate: params["activate"]?.bool ?? true)
    else { throw RPCError.failure("the browser could not open a tab") }
    return controller.describe(tab)
  }

  dispatcher.register("observe") { params in
    let tab = try controller.resolveTab(params)
    do {
      let observation = try await Observer.observe(
        transport: tab.channel, id: tab.nextObservationId(), tabId: tab.id,
        epoch: tab.control.epoch)
      tab.remember(observation)
      return observation.json
    } catch let error as CDPError {
      throw RPCError(error)
    } catch let error as ObservationError {
      throw RPCError.failure("\(error)")
    }
  }

  dispatcher.register("extract") { params in
    let tab = try controller.resolveTab(params)
    let name = params["format"]?.string ?? "text"
    guard let format = Extractor.Format(rawValue: name) else {
      throw RPCError.invalidParams("format must be text or markdown")
    }
    do {
      let content = try await Extractor.extract(
        transport: tab.channel, format: format, ref: params["ref"]?.int)
      return ["tabId": .string(tab.id), "format": .string(name), "content": .string(content)]
    } catch let error as CDPError {
      throw RPCError(error)
    }
  }
}
