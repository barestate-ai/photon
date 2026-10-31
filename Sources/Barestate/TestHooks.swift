import AppKit
import BarestateCore
import CoreImage

@MainActor private func modifiers(_ params: JSON) throws -> NSEvent.ModifierFlags {
  var flags: NSEvent.ModifierFlags = []
  for entry in params["modifiers"]?.array ?? [] {
    guard let name = entry.string, let flag = SyntheticInput.modifierFlags[name] else {
      throw RPCError.invalidParams("modifiers: cmd, shift, ctrl or alt")
    }
    flags.insert(flag)
  }
  return flags
}

/// Registered only under --test-hooks (the dispatcher also refuses `test.*` without it).
@MainActor
func registerTestHooks(
  _ dispatcher: RPCDispatcher, controller: AppController, actions: Actions,
  store: @escaping @MainActor () -> Store?
) {
  guard let app = NSApp as? BarestateApplication else { return }

  func window() throws -> NSWindow {
    guard let window = controller.window else { throw RPCError.failure("no window") }
    return window
  }

  func post(_ events: [NSEvent]) async -> JSON {
    await app.post(events)
    return ["posted": .number(Double(events.count))]
  }

  dispatcher.register("test.ui") { _ in
    let tabs = controller.tabs.map { tab -> JSON in
      var fields = controller.describe(tab).object ?? [:]
      fields["frame"] = windowRect(tab.view)
      fields["visible"] = .bool(!tab.view.isHiddenOrHasHiddenAncestor)
      fields["documentKey"] = tab.documentKey.map { .string($0) } ?? .null
      fields["epoch"] = .number(Double(tab.control.epoch))
      if case .agent(let session) = tab.control.controller {
        fields["controller"] = "agent"
        fields["controllerSession"] = .string(session)
      } else {
        fields["controller"] = "human"
      }
      fields["lastHumanInputMs"] = .number(tab.lastHumanInputMs)
      return .object(fields)
    }
    var responder = JSON.null
    if let view = controller.window?.firstResponder as? NSView {
      var owner: NSView? = view
      while let current = owner, !(current is TabContentView) { owner = current.superview }
      responder = [
        "class": .string(String(describing: type(of: view))),
        "tabId": (owner as? TabContentView).map { .string($0.tabId) } ?? .null,
        "chromeId": controller.chromeId(of: view).map { .string($0) } ?? .null,
      ]
    }
    return [
      "tabs": .array(tabs),
      "activeTabId": controller.activeTabId.map { .string($0) } ?? .null,
      "contentFrame": controller.container.map(windowRect) ?? .null,
      "windowFrame": json(controller.window?.frame ?? .zero),
      "window": controller.windowState(),
      "about": controller.aboutState(),
      "commandButton": controller.commandButtonState(),
      "orb": controller.orbState(),
      "caption": controller.captionState(),
      "presentation": .string(controller.presentation.rawValue),
      "cefBrowserCount": .number(Double(controller.cefBrowserCount)),
      "canvas": controller.canvasState(),
      "overview": controller.overviewState(),
      "focus": controller.focusState(),
      "chrome": controller.chromeState(),
      "launcher": controller.launcherState(),
      "activity": controller.activityState(),
      "settings": controller.settingsState(),
      "firstResponder": responder,
      "appActive": .bool(NSApp.isActive),
      "windowKey": .bool(controller.window?.isKeyWindow ?? false),
      "windowOnScreen": .bool(controller.window?.occlusionState.contains(.visible) ?? false),
      "visibleWindows": .array(
        NSApp.windows.filter(\.isVisible).map { .string(String(describing: type(of: $0))) }),
      "reduceMotion": .bool(controller.reduceMotion),
      "motion": controller.motionState(),
      "textScale": .number(controller.textScale),
      "approval": controller.approvalState(),
      "phone": controller.phoneState(),
    ]
  }

  dispatcher.register("test.screenshot") { params in
    let path = try params.requireString("path")
    let target =
      switch params["window"]?.string {
      case "settings": controller.settingsWindow?.window
      case "about": controller.aboutWindow
      default: nil as NSWindow?
      }
    guard let shot = target ?? controller.window else { throw RPCError.failure("no window") }
    try await capture(windowNumber: shot.windowNumber, to: path)
    return ["path": .string(path)]
  }

  dispatcher.register("test.devtools") { params in
    let tab = try controller.resolveTab(params)
    do {
      return try await tab.channel.send(
        try params.requireString("method"), params["params"] ?? [:])
    } catch let error as CDPError {
      throw RPCError(error)
    }
  }

  dispatcher.register("test.events") { params in
    let tab = try controller.resolveTab(params)
    let withParams = params["params"]?.bool ?? false
    let events = tab.events(since: params["since"]?.int ?? 0)
    return [
      "events": .array(
        events.map { entry in
          var fields: [String: JSON] = [
            "seq": .number(Double(entry.seq)), "method": .string(entry.event.method),
          ]
          if withParams { fields["params"] = entry.event.params }
          return .object(fields)
        }),
      "next": .number(Double(events.last?.seq ?? params["since"]?.int ?? 0)),
    ]
  }

  dispatcher.register("test.isolatedEval") { params in
    let tab = try controller.resolveTab(params)
    do {
      return try await Extractor.evaluateInIsolatedWorld(
        transport: tab.channel, expression: try params.requireString("expression"))
    } catch let error as CDPError {
      throw RPCError(error)
    }
  }

  dispatcher.register("test.holdDispatch") { params in
    let on = params["on"]?.bool ?? true
    actions.hold(on)
    return ["holding": .bool(on)]
  }

  func stub(_ value: JSON) -> Grounders.Stub? {
    if value.string == "abstain" { return .abstain }
    guard let x = value["x"]?.number, let y = value["y"]?.number else { return nil }
    return .point(Point(x: x, y: y))
  }

  /// Puts stubs or a fake runtime in place of the ladder's rungs, and reports what they were asked.
  dispatcher.register("test.grounding") { params in
    let grounders = actions.grounders
    if params["reset"]?.bool == true { await grounders.reset() }
    if let atom = params["atom"] {
      grounders.atomAbsent = atom.string == "absent"
      grounders.atomStub = stub(atom)
      if let launch = atom["launch"], let executable = launch["executable"]?.string {
        grounders.atomLaunch = AtomClient.Launch(
          executable: executable,
          arguments: launch["arguments"]?.array?.compactMap(\.string) ?? [],
          environment: launch["environment"]?.object?.compactMapValues(\.string) ?? [:])
      }
    }
    if let muse = params["muse"] { grounders.museStub = stub(muse) }
    if let policy = params["policy"], let hits = policy["hits"]?.int,
      let samples = policy["samples"]?.int
    {
      grounders.policy = GroundingPolicy(hits: hits, samples: samples)
    }
    return [
      "calls": .array(grounders.calls.map { .string($0) }),
      "hits": .number(Double(grounders.policy.hits)),
      "samples": .number(Double(grounders.policy.samples)),
      "atomNeedsApproval": .bool(grounders.policy.atomNeedsApproval),
    ]
  }

  /// Puts a stand-in for the model's reading of the verifier's screenshots, or the real model back
  /// (`mode: "live"`), and reports how often it was asked.
  dispatcher.register("test.verifier") { params in
    if let mode = params["mode"]?.string {
      if mode == "live" {
        actions.verifierStub = nil
      } else if let stub = Actions.VerifierStub(rawValue: mode) {
        actions.verifierStub = stub
      } else {
        throw RPCError.invalidParams("mode: agree, success, failure, unavailable or live")
      }
    }
    actions.verifierWhy = params["reason"]?.string ?? "stub"
    return [
      "mode": .string(actions.verifierStub?.rawValue ?? "live"),
      "calls": .number(Double(actions.verifierCalls)),
    ]
  }

  /// One real Atom grounding and its acceptance verdict, for the FT4 measurement.
  dispatcher.register("test.ground") { params in
    let tab = try controller.resolveTab(params)
    let found = await actions.grounders.measure(
      instruction: try params.requireString("instruction"), tab: tab)
    var fields: [String: JSON] = [
      "atomMs": .number(found.atomMs), "clientMs": .number(actions.grounders.clientMs),
    ]
    if let point = found.point { fields["point"] = ["x": .number(point.x), "y": .number(point.y)] }
    switch found.verdict {
    case .accepted(let ref):
      fields["verdict"] = "accepted"
      fields["ref"] = .number(Double(ref))
    case .rejected(let why): fields["verdict"] = .string(why.rawValue)
    case nil: fields["verdict"] = "no-point"
    }
    return .object(fields)
  }

  dispatcher.register("test.releaseDispatch") { _ in
    actions.hold(false)
    return ["holding": false]
  }

  dispatcher.register("test.key") { params in
    let name = try params.requireString("key")
    guard let stroke = SyntheticInput.stroke(for: name) else {
      throw RPCError.invalidParams("unknown key \(name)")
    }
    let target =
      params["window"]?.string == "settings" ? controller.settingsWindow?.window : controller.window
    guard let target else { throw RPCError.failure("no window") }
    return await post(
      SyntheticInput.keyEvents(
        stroke, modifiers: try modifiers(params), windowNumber: target.windowNumber,
        repeats: params["repeats"]?.int ?? 0,
        releaseModifiersFirst: params["releaseModifiersFirst"]?.bool ?? false,
        press: params["press"]?.bool ?? true, release: params["release"]?.bool ?? true))
  }

  dispatcher.register("test.type") { params in
    await post(
      SyntheticInput.typeEvents(
        try params.requireString("text"), windowNumber: try window().windowNumber))
  }

  dispatcher.register("test.ime") { params in
    guard let client = try window().firstResponder as? NSTextInputClient else {
      throw RPCError.failure("the first responder does not take text input")
    }
    if let tabId = BarestateApplication.tabId(containing: client as? NSView) {
      controller.humanInput(tabId: tabId)
    }
    let unmarked = NSRange(location: NSNotFound, length: 0)
    if let marked = params["marked"]?.string {
      client.setMarkedText(
        marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
        replacementRange: unmarked)
    } else if let committed = params["commit"]?.string {
      client.insertText(committed, replacementRange: unmarked)
    } else {
      throw RPCError.invalidParams("marked or commit (string) required")
    }
    return ["hasMarkedText": .bool(client.hasMarkedText())]
  }

  dispatcher.register("test.click") { params in
    guard let id = params["target"]?.string ?? params["tabId"]?.string,
      let view = controller.hookView(id)
    else {
      throw RPCError.invalidParams(
        "target (a view id: a tab id, \"commandButton\", \"findField\", \"launcherRow:<id>\", ...) required"
      )
    }
    guard !view.isHiddenOrHasHiddenAncestor else { throw RPCError.failure("\(id) is not visible") }
    // x and y are measured from the view's top left.
    let y = params["y"]?.number ?? view.bounds.height / 2
    let local = NSPoint(
      x: params["x"]?.number ?? view.bounds.width / 2,
      y: view.isFlipped ? y : view.bounds.height - y)
    let point = view.convert(local, to: nil)
    guard let win = view.window else { throw RPCError.failure("\(id) is not in a window") }
    // The first click on a window that was never truly key is consumed as an activating click.
    win.makeKey()
    let hit = win.contentView?.superview?.hitTest(point)
    let posted = await post(
      SyntheticInput.clickEvents(
        at: point, windowNumber: win.windowNumber, modifiers: try modifiers(params)))
    return [
      "posted": posted["posted"] ?? .null,
      "hit": .string(hit.map { String(describing: type(of: $0)) } ?? "none"),
    ]
  }

  var lastDrag = NSPoint.zero
  dispatcher.register("test.drag") { params in
    guard let id = params["target"]?.string, let view = controller.hookView(id),
      let win = view.window, !view.isHiddenOrHasHiddenAncestor
    else { throw RPCError.invalidParams("target (a visible view id) required") }
    let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    // dy grows downward, as everywhere else in the hooks.
    lastDrag = NSPoint(
      x: start.x + (params["dx"]?.number ?? 0), y: start.y - (params["dy"]?.number ?? 0))
    win.makeKey()
    return await post(
      SyntheticInput.dragEvents(
        from: start, to: lastDrag, windowNumber: win.windowNumber,
        release: params["release"]?.bool ?? true, steps: params["steps"]?.int ?? 1))
  }

  dispatcher.register("test.mouseUp") { _ in
    await post(SyntheticInput.releaseEvent(at: lastDrag, windowNumber: try window().windowNumber))
  }

  dispatcher.register("test.menu") { params in
    guard let main = NSApp.mainMenu else { throw RPCError.failure("no main menu") }
    main.updateAll()
    if let title = params["invoke"]?.string {
      guard let item = main.firstItem(titled: title), item.isEnabled, let action = item.action
      else {
        throw RPCError.failure("no enabled menu item \(title)")
      }
      NSApp.sendAction(action, to: item.target, from: item)
      return ["invoked": .string(title)]
    }
    return .array(main.items.map(menuJSON))
  }

  dispatcher.register("test.activateTab") { params in
    let id = try params.requireString("tabId")
    guard controller.tab(id: id) != nil else { throw RPCError.failure("unknown tab \(id)") }
    controller.activate(id)
    return ["activeTabId": .string(id)]
  }

  dispatcher.register("test.moveTab") { params in
    let id = try params.requireString("tabId")
    guard controller.tab(id: id) != nil, let index = params["index"]?.int else {
      throw RPCError.invalidParams("tabId (an open tab) and index (number) required")
    }
    controller.tabStore.move(id, to: index)
    return ["tabs": .array(controller.tabs.map { .string($0.id) })]
  }

  dispatcher.register("test.closeTab") { params in
    let id = try params.requireString("tabId")
    guard controller.tab(id: id) != nil else { throw RPCError.failure("unknown tab \(id)") }
    controller.closeTab(id, remember: true)
    return ["tabs": .number(Double(controller.tabs.count))]
  }

  dispatcher.register("test.windowSize") { params in
    guard let width = params["w"]?.number, let height = params["h"]?.number else {
      throw RPCError.invalidParams("w and h (numbers) required")
    }
    try window().setContentSize(NSSize(width: width, height: height))
    return ["windowFrame": json(try window().frame)]
  }

  dispatcher.register("test.textScale") { params in
    guard let scale = params["scale"]?.number, scale > 0 else {
      throw RPCError.invalidParams("scale (number > 0) required")
    }
    controller.textScale = scale
    return ["textScale": .number(scale)]
  }

  // Key status can go to the browser window while Settings stays on top, as it does when a locked
  // or backgrounded session finishes activating late.
  dispatcher.register("test.keyMainWindow") { _ in
    try window().makeKey()
    return [:]
  }

  dispatcher.register("test.reduceMotion") { params in
    guard let on = params["on"]?.bool else { throw RPCError.invalidParams("on (bool) required") }
    controller.reduceMotion = on
    controller.refreshGraphViews()
    return ["reduceMotion": .bool(on)]
  }

  dispatcher.register("test.seed") { params in
    let history = (params["history"]?.array ?? []).compactMap { entry -> Store.HistoryRow? in
      guard let url = entry["url"]?.string else { return nil }
      return Store.HistoryRow(
        url: url, title: entry["title"]?.string ?? "", visits: entry["visits"]?.int ?? 1,
        lastVisit: entry["lastVisit"]?.number ?? Date().timeIntervalSince1970)
    }
    let bookmarks = (params["bookmarks"]?.array ?? []).compactMap { entry -> Store.BookmarkRow? in
      guard let url = entry["url"]?.string else { return nil }
      return Store.BookmarkRow(
        url: url, title: entry["title"]?.string ?? "",
        createdAt: entry["createdAt"]?.number ?? Date().timeIntervalSince1970)
    }
    if let store = store() {
      do {
        try await store.seed(history: history, bookmarks: bookmarks)
      } catch {
        throw RPCError.failure("seed failed: \(error)")
      }
      await controller.launcher.reload()
    }
    let opened = (params["tabs"]?.array ?? []).compactMap { entry in
      entry.string.flatMap { controller.openTab(url: $0, activate: false)?.id }
    }
    return ["tabIds": .array(opened.map { .string($0) })]
  }

  // Crashes the app on purpose, after the reply, to check what the crash handlers record.
  // `exception` raises from a main-queue block, `task` inside a Task on the main actor, `action`
  // from a view's mouseDown dispatched by the run loop (the only route that reaches
  // `reportException:`).
  dispatcher.register("test.raise") { params in
    switch params["kind"]?.string {
    case "exception":
      DispatchQueue.main.async { raiseTestException() }
    case "task":
      Task { @MainActor in raiseTestException() }
    case "action":
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.contentView = RaisingView(frame: window.contentLayoutRect)
      window.isReleasedWhenClosed = false
      window.orderBack(nil)
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)
      if let event { app.postEvent(event, atStart: false) }
    case "signal":
      DispatchQueue.main.async { _ = raise(SIGSEGV) }
    default:
      throw RPCError.invalidParams("kind must be exception, task, action or signal")
    }
    return ["raising": params["kind"] ?? .null]
  }

  dispatcher.register("test.modelOffline") { params in
    guard let on = params["on"]?.bool else { throw RPCError.invalidParams("on (bool) required") }
    controller.modelOffline = on
    controller.launcher.availabilityChanged()
    return ["modelOffline": .bool(on)]
  }

  // Pairs a device as Settings does and returns the raw token, which nothing stores.
  dispatcher.register("test.pairToken") { params in
    guard let token = controller.remote.pair(label: params["label"]?.string ?? "Test device")
    else { throw RPCError.failure("the pairing could not be saved") }
    return ["token": .string(token), "hash": .string(PairingStore.hash(token))]
  }

  // What a QR code in a PNG says, read the way a phone would.
  dispatcher.register("test.qrDecode") { params in
    guard let path = params["path"]?.string,
      let image = CIImage(contentsOf: URL(fileURLWithPath: path)),
      let detector = CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    else { throw RPCError.invalidParams("path to a readable image required") }
    let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    return ["messages": .array(found.map { .string($0) })]
  }

  // Every accessibility announcement the app asked for, oldest first.
  dispatcher.register("test.announcements") { params in
    let all = controller.announcements
    if params["reset"]?.bool ?? false { controller.clearAnnouncements() }
    return ["announcements": .array(all.map { .string($0) })]
  }

  // Milliseconds from the key-down at `sendEvent` to a laid-out panel (open) or to the rows of
  // that generation (update).
  dispatcher.register("test.launcherTimings") { params in
    let launcher = controller.launcher
    let result: JSON = [
      "open": .array(launcher.openTimes.map { .number($0) }),
      "update": .array(launcher.updateTimes.map { .number($0) }),
    ]
    if params["reset"]?.bool ?? false { launcher.resetTimes() }
    return result
  }

  // Milliseconds from the ⌘⇧\ key-down at `sendEvent` to the settled presentation.
  dispatcher.register("test.toggleTimings") { params in
    let result: JSON = ["toggle": .array(controller.toggles.times.map { .number($0) })]
    if params["reset"]?.bool ?? false { controller.toggles.reset() }
    return result
  }

  dispatcher.register("test.ax") { params in
    if params["window"]?.string == "settings" {
      guard let settings = controller.settingsWindow?.window else {
        throw RPCError.failure("the settings window has not been opened")
      }
      return .array(accessibilityChildren(of: settings, in: settings))
    }
    let main = try window()
    // AppKit publishes the traffic lights through the window's own attributes; the buttons
    // themselves are not accessibility elements.
    let lights = [
      main.accessibilityCloseButton(), main.accessibilityMinimizeButton(),
      main.accessibilityZoomButton(),
    ].compactMap { $0 as? NSObject & NSAccessibilityProtocol }.map { button -> JSON in
      [
        "role": .string(button.accessibilityRole()?.rawValue ?? ""),
        "subrole": .string(button.accessibilitySubrole()?.rawValue ?? ""),
        "label": .string(button.accessibilityLabel() ?? button.accessibilityTitle() ?? ""),
        "enabled": .bool(button.isAccessibilityEnabled()),
        "actions": .array(button.accessibilityActionNames().map { .string($0.rawValue) }),
      ]
    }
    return .array(accessibilityChildren(of: main, in: main) + lights)
  }
}

/// The app's own accessibility tree. Web content is a leaf: its tree belongs to `observe`.
@MainActor
private func accessibilityChildren(of element: Any, in window: NSWindow, depth: Int = 0) -> [JSON] {
  guard depth < 8, let element = element as? NSAccessibilityProtocol else { return [] }
  return (element.accessibilityChildren() ?? []).filter {
    !String(describing: type(of: $0)).hasPrefix("_NSTheme")
  }.map { child in
    var fields: [String: JSON] = [:]
    // A control's label lives on the control; AppKit lists its cell, which also holds the role
    // and press action of a stock control (its control view reports `.unknown` and none).
    let cell = child as? NSCell
    let isCell = cell != nil
    let child = cell?.controlView ?? child
    if let child = child as? NSAccessibilityProtocol {
      let role =
        [child.accessibilityRole(), cell?.accessibilityRole()]
        .lazy.compactMap { $0 }.first { $0 != .unknown } ?? child.accessibilityRole()
      let label =
        [
          child.accessibilityLabel(), child.accessibilityTitle(),
          child.accessibilityValue() as? String,
        ]
        .lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
      fields["role"] = .string(role?.rawValue ?? "")
      fields["label"] = .string(label)
      fields["value"] = .string(child.accessibilityValue() as? String ?? "")
      fields["enabled"] = .bool(child.isAccessibilityEnabled())
      fields["selected"] = .bool(child.isAccessibilitySelected())
      // The accessibility focus flag stays false while the app is not frontmost (locked screen).
      fields["focused"] = .bool(window.firstResponder === child as AnyObject)
      fields["description"] = .string(child.accessibilityHelp() ?? "")
      // An NSAccessibilityElement has no action list; it presses when it overrides the press.
      let actions =
        child is NodeAccessibilityElement
        ? [NSAccessibility.Action.press]
        : [child, cell].lazy.compactMap { ($0 as? NSObject)?.accessibilityActionNames() }
          .first { !$0.isEmpty } ?? []
      fields["actions"] = .array(actions.map { .string($0.rawValue) })
      let screen = child.accessibilityFrame()
      fields["frame"] = [
        "x": .number(screen.minX - window.frame.minX),
        "y": .number(window.frame.maxY - screen.maxY),
        "w": .number(screen.width), "h": .number(screen.height),
      ]
    }
    if !isCell, !(child is TabContentView) {
      fields["children"] = .array(accessibilityChildren(of: child, in: window, depth: depth + 1))
    }
    return .object(fields)
  }
}

/// CEF renders through its own compositor, so a view snapshot would miss the page; the window
/// server's capture of our own window includes it.
@MainActor
private func capture(windowNumber: Int, to path: String) async throws {
  let status: Int32 = await withCheckedContinuation { continuation in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(windowNumber), path]
    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
    do {
      try process.run()
    } catch {
      continuation.resume(returning: -1)
    }
  }
  guard status == 0, FileManager.default.fileExists(atPath: path) else {
    throw RPCError.failure("screencapture failed (status \(status))")
  }
}

private func raiseTestException() {
  NSException(
    name: NSExceptionName("BarestateTestException"), reason: "test.raise exception", userInfo: nil
  ).raise()
}

private final class RaisingView: NSView {
  override func mouseDown(with event: NSEvent) { raiseTestException() }
}
