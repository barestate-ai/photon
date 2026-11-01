import AppKit
import BarestateCore
import CEFBridge

/// Chromium requires the NSApplication subclass to implement CrAppProtocol. It is also the first
/// code that sees every event, which is where human input bumps a tab's epoch.
final class BarestateApplication: BSApplication, CefAppProtocol {
  /// Set once the controller exists; events before that belong to no tab.
  weak var controller: AppController?

  /// Test hooks only: the system will not activate an app launched from a script, and Chromium
  /// drops mouse input while `isActive` is false.
  var alwaysActive = false

  override var isActive: Bool { alwaysActive || super.isActive }

  /// When the newest key-down reached `sendEvent`, on the same clock as the launcher's timings.
  private(set) var keyDownAt: UInt64 = 0
  private var handlingSendEvent = false
  private var synthetic: [Int64: CheckedContinuation<Void, Never>] = [:]
  private var swallowMouseUp = false

  func isHandlingSendEvent() -> Bool { handlingSendEvent }

  func setHandlingSendEvent(_ handlingSendEvent: Bool) {
    self.handlingSendEvent = handlingSendEvent
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown { keyDownAt = DispatchTime.now().uptimeNanoseconds }
    // Pinching in on a page leaves it a level at a time; the page never sees the gesture.
    if event.type == .magnify, controller?.pinchedOut(event) == true { return }
    // The second press of a double-click on a card may land on the page the first one opened.
    if event.type == .leftMouseDown, controller?.claimsDoubleClick(event) == true {
      swallowMouseUp = true
      return
    }
    if event.type == .leftMouseUp, swallowMouseUp {
      swallowMouseUp = false
      return
    }
    if event.type == .mouseMoved, event.window === controller?.window, let root = controller?.root {
      root.pointerMoved(to: root.convert(event.locationInWindow, from: nil))
    }
    let shortcut = shortcutItem(for: event)
    // Holding a key the app already acted on repeats that key-down, and the page it focused
    // must not get the repeats any more than the release.
    let heldConsumed =
      event.type == .keyDown && event.isARepeat && shortcut == nil
      && consumedKeys.contains(event.keyCode)
    if event.type == .keyDown, shortcut == nil, !consumedKeys.contains(event.keyCode) {
      controller?.landForPageKey(event)
    }
    // The bump must land before Chromium can hand the event to the page, so an action planned
    // against the earlier epoch is already stale by the time the page reacts. A shortcut is a
    // command that bumps for itself, not input to the page.
    // Tab on a page with an approval waiting is the person walking to the card, not taking over.
    if shortcut == nil, !heldConsumed, let tabId = Self.tabReceivingHumanInput(event),
      !(event.type == .keyDown && event.keyCode == 48
        && controller?.approvalsSurviveTab(on: tabId) == true)
    {
      controller?.humanInput(tabId: tabId)
    }
    let outer = handlingSendEvent
    handlingSendEvent = true
    defer {
      handlingSendEvent = outer
      synthetic.removeValue(forKey: EventStamp.tick(event.timestamp))?.resume()
    }
    if heldConsumed || swallowsKeyUp(event) || performShortcut(event) { return }
    super.sendEvent(event)
  }

  private var consumedKeys = Set<UInt16>()

  /// A key the app acted on in key-down: its release must not reach whatever that action focused.
  func consumeKeyUp(of keyCode: UInt16) { consumedKeys.insert(keyCode) }

  private func shortcutItem(for event: NSEvent) -> NSMenuItem? {
    guard event.type == .keyDown || event.type == .keyUp,
      !event.modifierFlags.intersection([.command, .control]).isEmpty
    else { return nil }
    return mainMenu?.item(matching: event)
  }

  func isShortcut(_ event: NSEvent) -> Bool { shortcutItem(for: event) != nil }

  /// AppKit's own key-equivalent search ignores Shift for an item without it, so Cmd-Shift-T
  /// would run New Tab. This search compares modifiers exactly and runs the action once. Holding
  /// a key repeats only tab switching; every other command fires on the first press.
  @discardableResult
  func performShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let item = shortcutItem(for: event), let action = item.action
    else {
      if event.type == .keyDown { consumedKeys.remove(event.keyCode) }
      return false
    }
    consumedKeys.insert(event.keyCode)
    if let launcher = controller?.launcher, launcher.isOpen,
      !launcher.allows(action, target: item.target)
    {
      return true
    }
    // A shortcut never does what the menu item, or the launcher row, says is unavailable.
    if let target = item.target as? AppController, !target.validateMenuItem(item) { return true }
    let repeatable =
      action == #selector(AppController.selectNextTab)
      || action == #selector(AppController.selectPreviousTab)
    if !event.isARepeat || repeatable { sendAction(action, to: item.target, from: item) }
    return true
  }

  /// The release of a consumed key never reaches the page, even when the modifiers were let go
  /// first and the release no longer looks like the shortcut.
  func swallowsKeyUp(_ event: NSEvent) -> Bool {
    event.type == .keyUp && (consumedKeys.remove(event.keyCode) != nil)
  }

  /// A control that tracks the mouse (a button) takes its mouse-up straight from the queue, so
  /// that event never reaches `sendEvent`; it counts as delivered once it is dequeued.
  override func nextEvent(
    matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode,
    dequeue: Bool
  ) -> NSEvent? {
    let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
    if dequeue, let event {
      let stamp = EventStamp.tick(event.timestamp)
      if synthetic[stamp] != nil {
        DispatchQueue.main.async { [weak self] in
          MainActor.assumeIsolated { self?.synthetic.removeValue(forKey: stamp)?.resume() }
        }
      }
    }
    return event
  }

  /// Posts events through the normal queue and returns once the last one has gone through
  /// `sendEvent`. Timestamps are unique per posted event and identify it on the way out.
  func post(_ events: [NSEvent]) async {
    guard let last = events.last else { return }
    for event in events { postEvent(event, atStart: false) }
    await withCheckedContinuation { continuation in
      synthetic[EventStamp.tick(last.timestamp)] = continuation
      // A dropped event must not hang the caller.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        MainActor.assumeIsolated {
          self?.synthetic.removeValue(forKey: EventStamp.tick(last.timestamp))?.resume()
        }
      }
    }
  }

  /// Mouse-downs, scrolls and gestures count when they land on a tab; a key-down counts when
  /// a tab's content is the first responder. Mouse-ups and moves do not, so a click is one bump.
  static func tabReceivingHumanInput(_ event: NSEvent) -> String? {
    guard let window = event.window else { return nil }
    let target: NSView?
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .rotate,
      .swipe, .smartMagnify:
      target = window.contentView?.superview?.hitTest(event.locationInWindow)
    case .keyDown:
      target = window.firstResponder as? NSView
    default:
      return nil
    }
    return tabId(containing: target)
  }

  static func tabId(containing view: NSView?) -> String? {
    var view = view
    while let current = view {
      if let tab = current as? TabContentView { return tab.tabId }
      view = current.superview
    }
    return nil
  }
}
