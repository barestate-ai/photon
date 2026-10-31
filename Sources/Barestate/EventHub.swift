import BarestateCore
import Foundation

/// Who is listening on the socket for app events (architecture §7), and the screencasts they
/// asked for. A subscriber that names a session is a phone's event stream: its presence is what
/// "Phone connected" means, and it ends when the client or the gateway goes away.
@MainActor
final class EventHub {
  private final class Subscriber {
    let peer: RPCPeer
    let session: String?
    let since = Date().timeIntervalSince1970
    var tabs: Set<String> = []

    init(peer: RPCPeer, session: String?) {
      self.peer = peer
      self.session = session
    }
  }

  private static let screencast: JSON = [
    "format": "jpeg", "quality": 55, "maxWidth": 540, "maxHeight": 960, "everyNthFrame": 1,
  ]

  private unowned let app: AppController
  private var subscribers: [ObjectIdentifier: Subscriber] = [:]
  /// What each event kind last said, so only a change is sent.
  private var last: [String: String] = [:]
  private var casting: Set<String> = []
  /// Called when a phone session opens or closes.
  var onSessionsChanged: (() -> Void)?

  init(app: AppController) { self.app = app }

  var phoneConnected: Bool { subscribers.values.contains { $0.session != nil } }

  func isOpen(_ session: String) -> Bool { subscribers.values.contains { $0.session == session } }

  func subscribe(_ peer: RPCPeer, session: String?) {
    let key = ObjectIdentifier(peer)
    guard subscribers[key] == nil else { return }
    subscribers[key] = Subscriber(peer: peer, session: session)
    peer.onClose { [weak self] in self?.left(key) }
    for event in snapshot() { peer.send(Self.notification(event.method, event.body), false) }
    if session != nil { onSessionsChanged?() }
  }

  func sessions() -> JSON {
    var named: [String: (since: Double, streams: Int)] = [:]
    for subscriber in subscribers.values {
      guard let name = subscriber.session else { continue }
      let known = named[name]
      named[name] = (
        min(known?.since ?? subscriber.since, subscriber.since), (known?.streams ?? 0) + 1
      )
    }
    let rows = named.sorted { $0.value.since < $1.value.since }.map { name, entry in
      JSON.object([
        "session": .string(name), "since": .number(entry.since),
        "streams": .number(Double(entry.streams)),
      ])
    }
    return ["sessions": .array(rows)]
  }

  /// Ends the session: its running phone tasks stop and its streams close. Returns the streams
  /// closed.
  @discardableResult
  func disconnect(session: String) -> Int {
    let streams = subscribers.values.filter { $0.session == session }
    guard !streams.isEmpty else { return 0 }
    app.runs.endRuns(ofRemoteSession: session, reason: "disconnected")
    for stream in streams { stream.peer.disconnect() }
    return streams.count
  }

  func disconnectAll() {
    for session in Set(subscribers.values.compactMap(\.session)) { disconnect(session: session) }
  }

  // MARK: Screencast

  func screencast(_ peer: RPCPeer, tab: Tab, on: Bool) throws {
    guard let subscriber = subscribers[ObjectIdentifier(peer)] else {
      throw RPCError.failure("call events.subscribe first")
    }
    if on { subscriber.tabs.insert(tab.id) } else { subscriber.tabs.remove(tab.id) }
    reconcile(tab.id)
  }

  /// A screencast runs only while some subscriber wants that tab.
  private func reconcile(_ tabId: String) {
    let wanted = subscribers.values.contains { $0.tabs.contains(tabId) }
    guard let tab = app.tab(id: tabId) else {
      casting.remove(tabId)
      return
    }
    if wanted, casting.insert(tabId).inserted {
      tab.onScreencastFrame = { [weak self, weak tab] params in
        if let self, let tab { self.relay(params, from: tab) }
      }
      Task { _ = try? await tab.channel.send("Page.startScreencast", Self.screencast) }
    } else if !wanted, casting.remove(tabId) != nil {
      tab.onScreencastFrame = nil
      Task { _ = try? await tab.channel.send("Page.stopScreencast", [:]) }
    }
  }

  private func relay(_ params: JSON, from tab: Tab) {
    // Chromium sends no further frame until this one is acknowledged.
    if let ack = params["sessionId"] {
      Task { _ = try? await tab.channel.send("Page.screencastFrameAck", ["sessionId": ack]) }
    }
    guard let data = params["data"]?.string else { return }
    let size = params["metadata"]
    let line = Self.notification(
      "screencast.frame",
      [
        "tabId": .string(tab.id), "data": .string(data),
        "width": size?["deviceWidth"] ?? .null, "height": size?["deviceHeight"] ?? .null,
      ])
    for subscriber in subscribers.values where subscriber.tabs.contains(tab.id) {
      subscriber.peer.send(line, true)
    }
  }

  private func left(_ key: ObjectIdentifier) {
    guard let gone = subscribers.removeValue(forKey: key) else { return }
    for tabId in gone.tabs { reconcile(tabId) }
    if gone.session != nil { onSessionsChanged?() }
  }

  // MARK: Events

  /// Sends what changed since the last call: a run, the tab list, the approval list.
  func publish() {
    guard !subscribers.isEmpty else { return }
    for event in snapshot() where last[event.key] != event.body.serialized() {
      last[event.key] = event.body.serialized()
      let line = Self.notification(event.method, event.body)
      for subscriber in subscribers.values { subscriber.peer.send(line, false) }
    }
    for tabId in casting where app.tab(id: tabId) == nil { casting.remove(tabId) }
  }

  private func snapshot() -> [(key: String, method: String, body: JSON)] {
    var events = app.runs.runs.map {
      (
        key: "run:" + $0.id, method: "run.update",
        body: RunController.json($0, session: app.runs.session($0.id))
      )
    }
    events.append(
      (key: "tabs", method: "tab.update", body: ["tabs": .array(app.tabs.map(app.describe))]))
    events.append(
      (
        key: "approvals", method: "approval.update",
        body: ["approvals": .array(app.approvals.items.map(Approvals.json))]
      ))
    return events
  }

  private static func notification(_ method: String, _ params: JSON) -> Data {
    let message: JSON = ["jsonrpc": "2.0", "method": .string(method), "params": params]
    return Data(message.serialized().utf8)
  }
}

@MainActor
func registerEventMethods(_ dispatcher: RPCDispatcher, controller: AppController) {
  let hub = controller.events

  func peer() throws -> RPCPeer {
    guard let peer = RPCContext.peer else { throw RPCError.failure("not a socket client") }
    return peer
  }

  dispatcher.register("events.subscribe") { params in
    if let session = params["session"], session.string == nil {
      throw RPCError.invalidParams("session must be a string")
    }
    hub.subscribe(try peer(), session: params["session"]?.string)
    return ["subscribed": true]
  }

  for (method, on) in [("screencast.start", true), ("screencast.stop", false)] {
    dispatcher.register(method) { params in
      _ = try params.requireString("tabId")
      let tab = try controller.resolveTab(params)
      try hub.screencast(try peer(), tab: tab, on: on)
      return ["tabId": .string(tab.id), "active": .bool(on)]
    }
  }

  dispatcher.register("remote.sessions") { _ in hub.sessions() }

  dispatcher.register("remote.disconnect") { params in
    ["closed": .number(Double(hub.disconnect(session: try params.requireString("session"))))]
  }
}
