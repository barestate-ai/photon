import AppKit
import BarestateCore
import CEFBridge

/// Under test hooks the window reports itself key even when macOS refuses to activate the app
/// (activation is cooperative since macOS 14), because Chromium ignores input to a window that
/// is not key.
final class BarestateWindow: NSWindow {
  var alwaysKey = false

  override var isKeyWindow: Bool { alwaysKey || super.isKeyWindow }
  override var canBecomeKey: Bool { true }
}

/// Hosts one browser. Created once per tab and never reparented, so CEF never loses its surface.
final class TabContentView: NSView {
  var tabId = ""
}

@MainActor
final class Tab {
  static let observationLimit = 8
  static let eventLimit = 256

  let id: String
  let browserId: Int32
  let view: TabContentView
  let channel: CDPChannel
  var url: String
  var title = ""
  var loading = true
  var canGoBack = false
  var canGoForward = false
  var security = SSLState.unknown
  /// The address whose load a bad certificate refused; Chromium shows an error page in its place.
  var certificateFailure: String?
  var control = TabControl() {
    didSet { if control != oldValue { controlChanged?() } }
  }
  /// Called when the controller or the epoch changed, so what was asked of the old one can lapse.
  var controlChanged: (() -> Void)?
  /// How this page came to be, until it commits and becomes a node of the page graph.
  var origin = NewTabOrigin.none
  /// The main frame's current document (frame id and loader id), for stamping previews; nil
  /// until the tab is a node of the page graph and its document was read.
  var documentKey: String?
  /// Counts committed main-frame navigations, so a capture can tell one happened while it ran.
  var documentGeneration = 0
  var lastHumanInputMs: Double = 0
  var observations: [Observation] = []
  let settling = Settling()
  private(set) var events: [(seq: Int, event: CDPEvent)] = []
  private var nextSeq = 1
  /// Screencast frames go here instead of the event log: they are large and only ever live.
  var onScreencastFrame: ((JSON) -> Void)?

  init(browserId: Int32, view: TabContentView, url: String) {
    id = "t\(browserId)"
    self.browserId = browserId
    self.view = view
    self.url = url
    view.tabId = id
    let browserId = browserId
    channel = CDPChannel { message in BSCef.sendDevToolsMessage(message, toBrowser: browserId) }
    let stream = channel.events
    Task { @MainActor [weak self] in
      for await event in stream { self?.record(event) }
    }
  }

  var caption: PageCaption? {
    PageCaption.make(url: url, title: title, ssl: security, certificateFailure: certificateFailure)
  }

  /// The failure belongs to the load it refused: any other real address clears it, whichever of
  /// the address change and the load error arrives first.
  func adopt(url: String) {
    self.url = url
    if let failed = certificateFailure, url != failed, !url.hasPrefix("chrome-error:") {
      certificateFailure = nil
    }
  }

  private var observationCount = 0

  func nextObservationId() -> String {
    observationCount += 1
    return "\(id)-o\(observationCount)"
  }

  func remember(_ observation: Observation) {
    observations.append(observation)
    if observations.count > Self.observationLimit { observations.removeFirst() }
  }

  func observation(id: String) -> Observation? {
    observations.first { $0.id == id }
  }

  func events(since seq: Int) -> [(seq: Int, event: CDPEvent)] {
    events.filter { $0.seq > seq }
  }

  private func record(_ event: CDPEvent) {
    if event.method == "Page.screencastFrame" {
      onScreencastFrame?(event.params)
      return
    }
    settling.feed(event)
    events.append((nextSeq, event))
    nextSeq += 1
    if events.count > Self.eventLimit { events.removeFirst() }
  }
}
