import AppKit
import BarestateCore
import CoreImage

/// A button the Tab loop always visits: without Full Keyboard Access AppKit skips buttons, and a
/// focused button does not run the loop for Tab or press for Space on its own.
private final class KeyButton: NSButton {
  override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
  override var acceptsFirstResponder: Bool { isEnabled }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 48: moveKeyFocus(event)
    case 36, 49, 76: performClick(nil)
    default: super.keyDown(with: event)
    }
  }
}

/// Holds focus until a control takes it, so Tab starts the key loop from the keyboard alone.
private final class SettingsRoot: NSView {
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { false }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 { moveKeyFocus(event) } else { super.keyDown(with: event) }
  }
}

/// The ⌘, window. Each control changes the live app through `AppController` and is saved to
/// settings.json there, so the window itself keeps no state beyond what it shows.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  private static let qrSide: CGFloat = 180
  private static let modelKeyNote =
    "Muse needs a key in the environment, the .env file or the Keychain item meta-model-api."
  static let reduceMotionNote =
    "Photon follows the system Reduce Motion setting. When it is on, movement on the canvas happens at once."

  let window: BarestateWindow
  private unowned let controller: AppController
  private var engineButtons: [(engine: SearchEngine, button: NSButton)] = []
  private let modelStatus = NSTextField(labelWithString: "")
  private let museTitle = NSTextField(labelWithString: "")
  private let museNote = SettingsWindow.noteLabel("")
  private let inviteField = NSTextField()
  private let museButton = KeyButton()
  private let museError = SettingsWindow.noteLabel("")
  /// While a connect call is out; the error line lives until the next attempt or a reopen.
  private var museConnecting = false
  /// How many connects were attempted, so a test can tell one click from two.
  private(set) var museConnects = 0
  private let atomStatus = NSTextField(labelWithString: "")
  private let atomNote = SettingsWindow.noteLabel("")
  private let atomButton = KeyButton()
  private let content = NSStackView()
  private let remoteToggle = KeyButton()
  private let remoteStatus = SettingsWindow.noteLabel("")
  private let pairButton = KeyButton()
  private let qrView = NSImageView()
  private let qrNote = SettingsWindow.noteLabel(
    "Scan with your phone's camera. This code is shown once.")
  private let devicesList = NSStackView()
  private(set) var sectionTitles: [String] = []
  /// How many times the window has closed, so a test waits for the close itself.
  private(set) var closeCount = 0
  /// How many times an engine was chosen, so a test can tell one keypress from two.
  private(set) var engineChanges = 0
  /// What the Atom section shows; Ready is the same check the act ladder makes.
  private enum AtomInstallState: Equatable {
    case ready, notInstalled, installing
    case failed(String)
  }
  private var atomInstallState: AtomInstallState = .notInstalled {
    didSet { if oldValue != atomInstallState { applyAtomState(fade: window.isVisible) } }
  }
  /// The one installer in flight; while it runs, the Atom button reads Cancel install.
  private var installer: AtomInstall?
  /// Counters a test waits on: installs started and progress lines shown.
  private(set) var atomInstalls = 0
  private(set) var atomLines = 0

  init(controller: AppController) {
    self.controller = controller
    window = BarestateWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "Settings"
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.backgroundColor = Design.canvas
    let root = SettingsRoot()
    root.addSubview(makeContent())
    window.contentView = root
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: root.topAnchor),
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      content.widthAnchor.constraint(equalToConstant: 480),
    ])
    window.makeFirstResponder(root)
    window.setAccessibilityLabel("Settings")
    refresh()
  }

  /// Without an active app (a scripted or locked session) AppKit does not hand key status back,
  /// and the main window then drops every key event.
  func windowWillClose(_ notification: Notification) {
    closeCount += 1
    hideQR()
    controller.window?.makeKey()
  }

  /// A closed window can keep reporting key until another window takes over.
  var isFront: Bool { window.isVisible && window.isKeyWindow }

  func show() {
    museError.stringValue = ""  // a failed attempt's line does not outlive the window
    refresh()
    if !window.isVisible { window.center() }
    // An inactive app never makes the window key, and the next ⌘W would then miss it.
    if controller.testHooks { controller.activateApp() }
    window.makeKeyAndOrderFront(nil)
  }

  /// Brings every control in line with the controller, whoever changed the setting.
  func refresh() {
    for (engine, button) in engineButtons {
      button.state = engine.template == controller.settings.searchEngine ? .on : .off
    }
    applyMuse(fade: false)  // sets the Model row's status too
    refreshAtom()
    let remote = controller.remote
    remoteToggle.state = remote.isRequested ? .on : .off
    remoteStatus.stringValue = remote.statusText
    pairButton.isEnabled = remote.isOn
    if !remote.isOn { hideQR() }
    showDevices()
    window.recalculateKeyViewLoop()
    fit()
  }

  var remoteState: JSON {
    [
      "on": .bool(controller.remote.isOn), "status": .string(controller.remote.statusText),
      "qrShown": .bool(!qrView.isHidden),
      "devices": .array(
        controller.remote.devices.map { device in
          [
            "label": .string(device.pairing.label), "hash": .string(device.pairing.hash),
            "created": .string(device.pairing.created),
            "lastSeen": device.lastSeen.map { .string($0) } ?? .null,
          ]
        }),
    ]
  }

  var selectedEngine: String? {
    engineButtons.first { $0.button.state == .on }?.engine.name
  }

  var modelStatusText: String { modelStatus.stringValue }

  var atomState: JSON {
    let state: String
    switch atomInstallState {
    case .ready: state = "ready"
    case .notInstalled: state = "not-installed"
    case .installing: state = "installing"
    case .failed: state = "failed"
    }
    return [
      "state": .string(state),
      "detail": .string(atomNote.isHidden ? "" : atomNote.stringValue),
      "installs": .number(Double(atomInstalls)),
      "lines": .number(Double(atomLines)),
    ]
  }

  /// Labels of the controls Tab visits, in order, starting after the content view, once round.
  var keyLoop: [String] {
    var visited: [NSView] = []
    var view = window.contentView?.nextValidKeyView
    while let current = view, !visited.contains(current) {
      visited.append(current)
      view = current.nextValidKeyView
    }
    return visited.map { $0.accessibilityLabel() ?? "" }
  }

  /// A focused text field answers through its field editor, which carries no label of its own.
  var focusedLabel: String? {
    if let view = window.firstResponder as? NSView, let label = view.accessibilityLabel() {
      return label
    }
    return ((window.firstResponder as? NSTextView)?.delegate as? NSView)?.accessibilityLabel()
  }

  /// Settings controls by the ids test hooks click.
  var controlsById: [String: NSView] {
    var found: [String: NSView] = [
      "settings.remote.enable": remoteToggle, "settings.remote.pair": pairButton,
      "settings.atom.install": atomButton,
      "settings.muse.invite": inviteField, "settings.muse.connect": museButton,
    ]
    for (engine, button) in engineButtons {
      found["settings.engine.\(engine.name.lowercased())"] = button
    }
    return found
  }

  // MARK: Building

  private func makeContent() -> NSView {
    let stack = content
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

    section("Search engine", in: stack)
    for engine in SearchEngine.all {
      let button = radio(engine.name, action: #selector(engineChosen(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(engine.template)
      engineButtons.append((engine, button))
      stack.addArrangedSubview(button)
    }

    section("Model", in: stack)
    modelStatus.font = Fonts.manrope(14)
    modelStatus.textColor = Design.ink
    modelStatus.setAccessibilityLabel("Model status")
    stack.addArrangedSubview(modelStatus)
    stack.addArrangedSubview(wrappedNote(Self.modelKeyNote))
    // Barestate Muse (D74): offered only when no key of the user's own resolves.
    museTitle.font = Fonts.manrope(14, weight: 500)
    museTitle.textColor = Design.ink
    museTitle.wantsLayer = true
    stack.addArrangedSubview(museTitle)
    museNote.preferredMaxLayoutWidth = 432
    museNote.lineBreakMode = .byWordWrapping
    museNote.maximumNumberOfLines = 0
    stack.addArrangedSubview(museNote)
    inviteField.placeholderString = "Invite code"
    inviteField.font = Fonts.manrope(14)
    inviteField.setAccessibilityLabel("Invite code")
    inviteField.widthAnchor.constraint(equalToConstant: 200).isActive = true
    museButton.bezelStyle = .rounded
    museButton.bezelColor = Design.petrol
    museButton.target = self
    museButton.action = #selector(musePressed)
    let connectRow = NSStackView(views: [inviteField, museButton])
    connectRow.orientation = .horizontal
    connectRow.spacing = 8
    connectRow.alignment = .centerY
    stack.addArrangedSubview(connectRow)
    museError.preferredMaxLayoutWidth = 432
    museError.lineBreakMode = .byWordWrapping
    museError.maximumNumberOfLines = 0
    stack.addArrangedSubview(museError)

    section("Atom", in: stack)
    atomStatus.font = Fonts.manrope(14)
    atomStatus.textColor = Design.ink
    atomStatus.wantsLayer = true
    atomStatus.setAccessibilityLabel("Atom status")
    stack.addArrangedSubview(atomStatus)
    atomNote.preferredMaxLayoutWidth = 432
    atomNote.lineBreakMode = .byWordWrapping
    atomNote.maximumNumberOfLines = 0
    stack.addArrangedSubview(atomNote)
    atomButton.bezelStyle = .rounded
    atomButton.bezelColor = Design.petrol
    atomButton.target = self
    atomButton.action = #selector(atomPressed)
    stack.addArrangedSubview(atomButton)

    section("Remote", in: stack)
    remoteToggle.setButtonType(.switch)
    remoteToggle.attributedTitle = inkTitle("Enable Remote")
    remoteToggle.setAccessibilityLabel("Enable Remote")
    remoteToggle.target = self
    remoteToggle.action = #selector(remoteToggled)
    stack.addArrangedSubview(remoteToggle)
    stack.addArrangedSubview(remoteStatus)
    pairButton.bezelStyle = .rounded
    pairButton.bezelColor = Design.petrol
    pairButton.attributedTitle = NSAttributedString(
      string: "Pair a phone",
      attributes: [.font: Fonts.manrope(14), .foregroundColor: Design.surface])
    pairButton.setAccessibilityLabel("Pair a phone")
    pairButton.target = self
    pairButton.action = #selector(pairPhone)
    stack.addArrangedSubview(pairButton)
    qrView.imageScaling = .scaleProportionallyUpOrDown
    qrView.wantsLayer = true
    qrView.isHidden = true
    qrView.setAccessibilityRole(.image)
    qrView.setAccessibilityLabel("Pairing QR code")
    qrNote.isHidden = true
    NSLayoutConstraint.activate([
      qrView.widthAnchor.constraint(equalToConstant: Self.qrSide),
      qrView.heightAnchor.constraint(equalToConstant: Self.qrSide),
    ])
    stack.addArrangedSubview(qrView)
    stack.addArrangedSubview(qrNote)
    stack.addArrangedSubview(body("Paired devices"))
    devicesList.orientation = .vertical
    devicesList.alignment = .leading
    devicesList.spacing = 8
    devicesList.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.addArrangedSubview(devicesList)
    devicesList.widthAnchor.constraint(equalToConstant: 432).isActive = true

    section("Motion", in: stack)
    stack.addArrangedSubview(wrappedNote(Self.reduceMotionNote))

    return stack
  }

  /// The Remote section grows and shrinks (QR code, paired devices), so the window follows,
  /// keeping its top edge where it is.
  private func fit() {
    window.layoutIfNeeded()
    let height = content.fittingSize.height
    var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: height))
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    window.setFrame(frame, display: true)
  }

  private func section(_ title: String, in stack: NSStackView) {
    sectionTitles.append(title)
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(24, after: last) }
    let label = NSTextField(labelWithString: title)
    label.font = Fonts.manrope(14, weight: 500)
    label.textColor = Design.ink
    label.setAccessibilityRole(.staticText)
    label.setAccessibilityLabel(title)
    stack.addArrangedSubview(label)
  }

  private func body(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Fonts.manrope(14)
    label.textColor = Design.ink
    return label
  }

  private func inkTitle(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text, attributes: [.font: Fonts.manrope(14), .foregroundColor: Design.ink])
  }

  private func note(_ text: String) -> NSTextField { Self.noteLabel(text) }

  private func wrappedNote(_ text: String) -> NSTextField {
    let label = note(text)
    label.preferredMaxLayoutWidth = 432
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
  }

  private static func noteLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Fonts.manrope(12)
    label.textColor = Design.muted
    return label
  }

  private func radio(_ title: String, action: Selector) -> NSButton {
    let button = KeyButton()
    button.setButtonType(.radio)
    button.target = self
    button.action = action
    button.attributedTitle = inkTitle(title)
    button.setAccessibilityLabel(title)
    return button
  }

  // MARK: Remote

  private func showDevices() {
    for key in controller.viewsById.keys where key.hasPrefix("settings.remote.revoke.") {
      controller.viewsById[key] = nil
    }
    for row in devicesList.arrangedSubviews { row.removeFromSuperview() }
    let devices = controller.remote.devices
    if devices.isEmpty { devicesList.addArrangedSubview(note("No paired devices.")) }
    for (pairing, lastSeen) in devices {
      let name = body(pairing.label)
      let detail = note(
        "Paired \(Self.when(pairing.created)) · Last seen \(lastSeen.map(Self.when) ?? "never")")
      let text = NSStackView(views: [name, detail])
      text.orientation = .vertical
      text.alignment = .leading
      text.spacing = 2
      let revoke = KeyButton()
      revoke.bezelStyle = .rounded
      revoke.attributedTitle = inkTitle("Revoke")
      revoke.setAccessibilityLabel("Revoke \(pairing.label)")
      revoke.identifier = NSUserInterfaceItemIdentifier(pairing.hash)
      revoke.target = self
      revoke.action = #selector(revokeDevice)
      controller.viewsById["settings.remote.revoke.\(pairing.hash.prefix(8))"] = revoke
      text.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let row = NSStackView(views: [text, revoke])
      row.orientation = .horizontal
      row.distribution = .fill
      row.alignment = .centerY
      devicesList.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: devicesList.widthAnchor).isActive = true
    }
  }

  private static func when(_ iso: String) -> String {
    ISO8601DateFormatter().date(from: iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
  }

  /// The code carries the only copy of the token this window ever sees, so it goes away with
  /// the window, with Remote, and with the next pairing.
  private func hideQR() {
    qrView.image = nil
    qrView.isHidden = true
    qrNote.isHidden = true
  }

  private func showQR(_ text: String) {
    let side = Self.qrSide
    guard
      let image = QRCode.image(
        text, dark: CIColor(color: Design.ink)!, light: CIColor(color: Design.surface)!)
    else { return Log.error(.remote, "qr code failed") }
    qrView.image = NSImage(cgImage: image, size: NSSize(width: side, height: side))
    qrView.isHidden = false
    qrNote.isHidden = false
    fit()
    let reduced = MotionLedger.shared.reduced()
    MotionLedger.shared.start(
      .qrReveal, target: "pairing",
      [
        .init(
          layer: qrView.layer!, key: "qr.reveal",
          animation: Motion.ease(
            "opacity", from: 0, to: 1,
            duration: reduced ? Motion.reducedFade : Motion.fadeSmall))
      ])
  }

  // MARK: Atom

  /// Re-resolves while no install runs, so an install or removal done outside this window shows
  /// correctly on the next open. The same `AtomConfig.resolve` the act ladder uses.
  private func refreshAtom() {
    if installer == nil {
      let installed =
        AtomConfig.resolve(
          environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
          resources: Bundle.main.resourcePath) != nil
      atomInstallState = installed ? .ready : .notInstalled
    }
    applyAtomState(fade: false)
  }

  private func applyAtomState(fade: Bool) {
    let status: String
    let note: String
    let button: String?
    switch atomInstallState {
    case .ready:
      status = "Ready"
      note = ""
      button = nil
    case .notInstalled:
      status = "Not installed"
      note = "Atom grounds clicks on the page before Photon asks Muse. Needs about 1.4 GB of disk."
      button = "Install Atom"
    case .installing:
      status = "Installing"
      note = atomNote.stringValue.isEmpty ? "Starting the installer" : atomNote.stringValue
      button = "Cancel install"
    case .failed(let reason):
      status = "Installation failed"
      note = reason
      button = "Try again"
    }
    let changed = atomStatus.stringValue != status
    atomStatus.stringValue = status
    atomNote.stringValue = note
    atomNote.isHidden = note.isEmpty
    atomButton.isHidden = button == nil
    if let button {
      atomButton.attributedTitle = NSAttributedString(
        string: button, attributes: [.font: Fonts.manrope(14), .foregroundColor: Design.surface])
      atomButton.setAccessibilityLabel(button)
    }
    // A small fade marks a state change while the window is on screen; the progress text that
    // streams during the install never animates.
    if fade, changed, let layer = atomStatus.layer {
      let reduced = MotionLedger.shared.reduced()
      MotionLedger.shared.start(
        .atomState, target: "settings-atom",
        [
          .init(
            layer: layer, key: "atom.state",
            animation: Motion.ease(
              "opacity", from: 0, to: 1,
              duration: reduced ? Motion.reducedFade : Motion.fadeSmall))
        ])
    }
    if window.isVisible { fit() }
  }

  @objc private func atomPressed() {
    if let installer {
      installer.cancel()
      return
    }
    let script = Bundle.main.resourcePath.map { "\($0)/atom/setup-atom.sh" }
    guard let script, FileManager.default.fileExists(atPath: script) else {
      atomInstallState = .failed("The installer is missing from this app.")
      return
    }
    let runner = AtomInstall(script: script)
    installer = runner
    atomInstalls += 1
    atomLines = 0
    atomNote.stringValue = ""
    atomInstallState = .installing
    Task {
      let outcome = await runner.run { [weak self] line in
        Task { @MainActor [weak self] in self?.atomProgress(line) }
      }
      installer = nil
      switch outcome {
      case .installed: atomInstallState = .ready
      case .cancelled: atomInstallState = .notInstalled
      case .failed(let reason): atomInstallState = .failed(reason)
      }
      Log.info(.runs, "atom install: \(outcome)")
    }
  }

  /// Quit: stops the installer in flight. The task ends once its whole process tree is gone, so
  /// the caller can wait for it before the process exits.
  func stopInstaller() -> Task<Void, Never>? {
    guard let installer else { return nil }
    return Task.detached { await installer.cancelAndWait(timeout: .seconds(2.5)) }
  }

  /// The latest installer line, shown while the install runs; a late line after it ends is dropped.
  private func atomProgress(_ line: String) {
    guard case .installing = atomInstallState else { return }
    atomLines += 1
    atomNote.stringValue = line
    fit()
  }

  // MARK: Barestate Muse

  /// Offered only when no key of the user's own resolves (D74): an invite code field and
  /// Connect, or Connected and Disconnect once this Mac holds a device token.
  /// `animateAnyway`: the caller knows the state just flipped even when an intermediate
  /// refresh (a connect's latch-clearing probe repaints Settings) already set the title.
  private func applyMuse(fade: Bool, animateAnyway: Bool = false) {
    // A token arriving or leaving flips Muse's availability; the row above reads it fresh.
    modelStatus.stringValue = controller.museOutage == nil ? "Available" : "Unavailable"
    let offered = !controller.ownModelKey
    let connected = controller.barestateMuseConnected
    let title: String
    let note: String
    let button: String?
    if !offered {
      title = ""
      note = ""
      button = nil
    } else if connected {
      title = "Barestate Muse"
      note = "This Mac is connected. Muse calls go through the Barestate API."
      button = "Disconnect"
    } else {
      title = "Use Barestate Muse"
      note =
        museConnecting
        ? "Connecting…"
        : "No key of your own? Enter an invite code to use Muse through the Barestate API."
      button = "Connect"
    }
    let changed = museTitle.stringValue != title
    museTitle.stringValue = title
    museTitle.isHidden = title.isEmpty
    museNote.stringValue = note
    museNote.isHidden = note.isEmpty
    inviteField.isHidden = !offered || connected
    inviteField.isEnabled = !museConnecting
    museButton.isHidden = button == nil
    museButton.isEnabled = !museConnecting
    if let button {
      museButton.attributedTitle = NSAttributedString(
        string: button, attributes: [.font: Fonts.manrope(14), .foregroundColor: Design.surface])
      museButton.setAccessibilityLabel(button)
    }
    museError.isHidden = museError.stringValue.isEmpty || !offered || connected
    // The same small status fade the Atom section uses for a state change (status-fade).
    if fade, changed || animateAnyway, !title.isEmpty, let layer = museTitle.layer {
      let reduced = MotionLedger.shared.reduced()
      MotionLedger.shared.start(
        .museState, target: "settings-muse",
        [
          .init(
            layer: layer, key: "muse.state",
            animation: Motion.ease(
              "opacity", from: 0, to: 1,
              duration: reduced ? Motion.reducedFade : Motion.fadeSmall))
        ])
    }
    if window.isVisible { fit() }
  }

  /// What `test.ui` reports for the Muse section.
  var museState: JSON {
    [
      "offered": .bool(!controller.ownModelKey),
      "connected": .bool(controller.barestateMuseConnected),
      "connecting": .bool(museConnecting),
      "error": .string(museError.isHidden ? "" : museError.stringValue),
      "connects": .number(Double(museConnects)),
    ]
  }

  @objc private func musePressed() {
    if controller.barestateMuseConnected {
      controller.disconnectBarestateMuse()
      museError.stringValue = ""
      applyMuse(fade: window.isVisible)
      return
    }
    let code = inviteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else {
      museError.stringValue = "Enter an invite code."
      applyMuse(fade: false)
      return
    }
    museConnecting = true
    museConnects += 1
    museError.stringValue = ""
    applyMuse(fade: false)
    Task {
      let error = await controller.connectBarestateMuse(inviteCode: code)
      museConnecting = false
      if let error {
        museError.stringValue = error
      } else {
        inviteField.stringValue = ""
      }
      applyMuse(fade: window.isVisible, animateAnyway: error == nil)
    }
  }

  // MARK: Actions

  @objc private func remoteToggled(_ sender: NSButton) {
    if sender.state == .on {
      controller.remote.enable()
    } else {
      controller.remote.disable()
    }
  }

  @objc private func pairPhone(_ sender: NSButton) {
    hideQR()
    guard let token = controller.remote.pair(), let url = controller.remote.pairingURL(token)
    else { return }
    showQR(url)
  }

  @objc private func revokeDevice(_ sender: NSButton) {
    guard let hash = sender.identifier?.rawValue else { return }
    controller.remote.revoke(hash: hash)
  }

  @objc private func engineChosen(_ sender: NSButton) {
    guard let template = sender.identifier?.rawValue else { return }
    engineChanges += 1
    controller.setSearchEngine(template)
  }
}
