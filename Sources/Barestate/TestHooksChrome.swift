import AppKit
import BarestateCore

func json(_ rect: NSRect) -> JSON {
  [
    "x": .number(rect.origin.x), "y": .number(rect.origin.y),
    "w": .number(rect.size.width), "h": .number(rect.size.height),
  ]
}

/// A view's frame in window points with the origin at the top left, as design.md measures.
@MainActor
func windowRect(_ view: NSView) -> JSON {
  guard let window = view.window else { return json(.zero) }
  var rect = view.convert(view.bounds, to: nil)
  rect.origin.y = window.frame.height - rect.maxY
  return json(rect)
}

/// State dumps and view lookup for `test.ui` and `test.click` (registered only with --test-hooks).
@MainActor
extension AppController {
  func hookView(_ id: String) -> NSView? {
    if let view = viewsById[id] { return view }
    guard let root, let colon = id.firstIndex(of: ":") else { return nil }
    let rest = String(id[id.index(after: colon)...])
    switch id[..<colon] {
    case "launcherRow": return root.launcher.rowView(id: rest)
    case "node":
      return presentation == .focused
        ? root.focusContext.probe(for: rest) : root.canvasView?.probe(for: rest)
    default: return nil
    }
  }

  func chromeId(of view: NSView) -> String? {
    if let row = view as? LauncherRowView { return "launcherRow:\(row.rowId)" }
    if let known = viewsById.first(where: { $0.value === view && !($0.value is TabContentView) }) {
      return known.key
    }
    guard let text = view as? NSText, let root else { return nil }
    if text.delegate === root.findBar.field { return "findField" }
    if text.delegate === root.launcher.field { return "launcherField" }
    if text.delegate === root.canvasView?.titleField { return "canvasTitle" }
    return nil
  }

  func windowState() -> JSON {
    guard let window else { return .null }
    var lights: [String: JSON] = [:]
    for (name, type) in [
      ("close", NSWindow.ButtonType.closeButton), ("miniaturize", .miniaturizeButton),
      ("zoom", .zoomButton),
    ] {
      lights[name] = window.standardWindowButton(type).map(windowRect) ?? .null
    }
    return [
      "title": .string(window.title),
      "titlebarTransparent": .bool(window.titlebarAppearsTransparent),
      "titleHidden": .bool(window.titleVisibility == .hidden),
      "fullSizeContent": .bool(window.styleMask.contains(.fullSizeContentView)),
      "toolbar": .bool(window.toolbar != nil),
      "titlebarAccessories": .number(Double(window.titlebarAccessoryViewControllers.count)),
      "trafficLights": .object(lights),
      "minContentSize": [
        "w": .number(window.contentMinSize.width), "h": .number(window.contentMinSize.height),
      ],
    ]
  }

  /// The standard About panel, the only other window the app opens besides Settings.
  var aboutWindow: NSWindow? {
    NSApp.windows.first {
      $0.isVisible && $0 !== window && $0 !== settingsWindow?.window && $0 is NSPanel
    }
  }

  func aboutState() -> JSON {
    guard let panel = aboutWindow, let content = panel.contentView else { return ["open": false] }
    var texts: [JSON] = []
    var images = 0
    func walk(_ view: NSView) {
      if let field = view as? NSTextField { texts.append(.string(field.stringValue)) }
      if let text = view as? NSTextView { texts.append(.string(text.string)) }
      if view is NSImageView { images += 1 }
      view.subviews.forEach(walk)
    }
    walk(content)
    return ["open": true, "texts": .array(texts), "images": .number(Double(images))]
  }

  func commandButtonState() -> JSON {
    guard let root else { return .null }
    let button = root.commandButton
    return [
      "frame": windowRect(button), "visible": .bool(!button.isHiddenOrHasHiddenAncestor),
      "label": .string(button.accessibilityLabel() ?? ""), "hint": .string(button.hintText),
      "focused": .bool(window?.firstResponder === button),
      "compactChip": .bool(root.compactChipVisible),
    ]
  }

  func orbState() -> JSON {
    guard let root else { return .null }
    let orb = root.orb
    return [
      "visible": .bool(!orb.isHidden),
      "variant": .string(orb.shown ? (orb.working ? "working" : "thinking") : ""),
      "runId": .string(orb.runId),
      "spinning": .bool(orb.spinning),
      "frame": windowRect(orb),
    ]
  }

  func captionState() -> JSON {
    guard let root else { return .null }
    let view = root.caption
    guard let shown = view.shown else {
      return ["visible": false, "title": "", "host": "", "security": ""]
    }
    return [
      "visible": .bool(!view.isHidden), "title": .string(shown.title), "host": .string(shown.host),
      "security": .string(shown.security.rawValue), "text": .string(view.detailText),
      "fits": .bool(view.detailFits), "frame": windowRect(view),
    ]
  }

  func chromeState() -> JSON {
    guard let root else { return .null }
    let find = root.findBar
    let button = root.commandButton
    return [
      "find": [
        "open": .bool(!find.isHidden), "text": .string(find.text),
        "matches": .number(Double(find.matches)), "active": .number(Double(find.active)),
        "focused": .bool(find.hasFocus), "frame": windowRect(find),
      ],
      "fonts": [
        "manrope": fontJSON(Fonts.manropeRegistration, inUse: Fonts.manrope(14).fontName),
        "instrumentSerif": fontJSON(Fonts.serifRegistration, inUse: Fonts.serif(14).fontName),
      ],
      "text": [
        "commandLabel": .string(button.labelFont?.fontName ?? ""),
        "commandKey": .string(button.keyFont?.fontName ?? ""),
        "findField": .string(find.field.font?.fontName ?? ""),
        "launcherField": .string(root.launcher.field.font?.fontName ?? ""),
        "launcherEditor": editorTextState(root.launcher.field),
        "launcherHint": .string(root.launcher.keyChips.first?.label.font?.fontName ?? ""),
      ],
    ]
  }

  /// The fonts the launcher's field editor actually holds: every run of its text, and what the
  /// next typed character takes. One entry each means one weight and size throughout.
  private func editorTextState(_ field: NSTextField) -> JSON {
    guard let editor = field.currentEditor() as? NSTextView, let storage = editor.textStorage
    else { return .null }
    func describe(_ font: NSFont) -> JSON {
      let axes = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
      let weight = axes?[NSNumber(value: Fonts.weightAxis)]?.doubleValue ?? 0
      return [
        "name": .string(font.fontName), "size": .number(font.pointSize), "weight": .number(weight),
      ]
    }
    var runs: [JSON] = []
    storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      let json = describe((value as? NSFont) ?? NSFont.systemFont(ofSize: 0))
      if !runs.contains(json) { runs.append(json) }
    }
    return [
      "runs": .array(runs),
      "typing": describe(
        (editor.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 0)),
      "idealMetrics": .bool(editor.layoutManager?.usesScreenFonts == false),
    ]
  }

  private func fontJSON(_ registration: Fonts.Registration, inUse: String?) -> JSON {
    [
      "registered": .bool(registration.registered),
      "url": .string(registration.url?.path ?? ""),
      "inUse": .string(inUse ?? ""),
    ]
  }
}

@MainActor
extension AppController {
  func settingsState() -> JSON {
    var fields: [String: JSON] = [
      "searchEngine": .string(settings.searchEngine),
      "open": .bool(settingsWindow?.window.isVisible ?? false),
      "windows": .number(
        Double(NSApp.windows.filter { $0.title == "Settings" && $0.isVisible }.count)),
    ]
    if let settingsWindow {
      fields["frame"] = json(settingsWindow.window.frame)
      fields["sections"] = .array(settingsWindow.sectionTitles.map { .string($0) })
      fields["selectedEngine"] = settingsWindow.selectedEngine.map { .string($0) } ?? .null
      fields["model"] = .string(settingsWindow.modelStatusText)
      fields["key"] = .bool(settingsWindow.window.isKeyWindow)
      fields["closes"] = .number(Double(settingsWindow.closeCount))
      fields["engineChanges"] = .number(Double(settingsWindow.engineChanges))
      fields["keyLoop"] = .array(settingsWindow.keyLoop.map { .string($0) })
      fields["focused"] = settingsWindow.focusedLabel.map { .string($0) } ?? .null
      fields["remote"] = settingsWindow.remoteState
    }
    return .object(fields)
  }
}

extension NSMenu {
  /// AppKit validates a submenu's items only when it is about to show, which is when titles and
  /// checks refresh.
  func updateAll() {
    update()
    for item in items { item.submenu?.updateAll() }
  }

  func firstItem(titled title: String) -> NSMenuItem? {
    for item in items {
      if item.title == title { return item }
      if let found = item.submenu?.firstItem(titled: title) { return found }
    }
    return nil
  }
}

@MainActor
func menuJSON(_ item: NSMenuItem) -> JSON {
  if item.isSeparatorItem { return ["separator": true] }
  let mask = item.keyEquivalentModifierMask
  var names: [JSON] = []
  var glyphs = ""
  for (flag, name, glyph) in [
    (NSEvent.ModifierFlags.control, "ctrl", "⌃"), (.option, "alt", "⌥"), (.shift, "shift", "⇧"),
    (.command, "cmd", "⌘"),
  ] where mask.contains(flag) {
    names.append(.string(name))
    glyphs += glyph
  }
  var fields: [String: JSON] = [
    "title": .string(item.submenu?.title ?? item.title),
    "enabled": .bool(item.isEnabled), "toolTip": .string(item.toolTip ?? ""),
    "checked": .bool(item.state == .on), "key": .string(item.keyEquivalent),
    "modifiers": .array(names),
    "shortcut": .string(item.keyEquivalent.isEmpty ? "" : glyphs + item.keyEquivalent.uppercased()),
  ]
  if let submenu = item.submenu {
    fields["items"] = .array(submenu.items.map(menuJSON))
  }
  return .object(fields)
}

@MainActor
extension AppController {
  func launcherState() -> JSON {
    guard let view = root?.launcher else { return .null }
    let model = launcher.model
    let rows = model.rows.map { row -> JSON in
      let rowView = view.rowView(id: row.id)
      let shown = view.isShown(row.id)
      return [
        "id": .string(row.id), "kind": .string(row.kind.rawValue), "title": .string(row.title),
        "subtitle": .string(row.subtitle), "actionLabel": .string(row.actionLabel),
        "target": .string(row.target), "enabled": .bool(row.enabled),
        "section": .string(row.section), "status": .string(row.status.rawValue),
        "owner": row.owner.map { .string($0) } ?? .null,
        "active": .bool(row.id == model.activeId), "visible": .bool(shown),
        "state": .string(rowView?.state ?? "default"),
        "hint": .bool(shown && rowView?.showsHint == true),
        "focused": .bool(rowView?.hasFocus ?? false),
        "frame": shown ? rowView.map(windowRect) ?? .null : .null,
      ]
    }
    let sections = LauncherSection.group(model.rows).map { section -> JSON in
      ["title": .string(section.title), "rows": .array(section.rows.map { .string($0.id) })]
    }
    let editor = view.field.currentEditor() as? NSTextView
    return [
      "open": .bool(launcher.isOpen), "query": .string(model.query),
      "scope": .string(model.scope.rawValue),
      "location": .bool(launcher.navigatesCurrentTab),
      "fieldText": .string(view.field.stringValue),
      "selection": editor.map { range in
        [
          "location": .number(Double(range.selectedRange.location)),
          "length": .number(Double(range.selectedRange.length)),
        ]
      } ?? .null,
      "active": model.activeId.map { .string($0) } ?? .null, "rows": .array(rows),
      "sections": .array(sections),
      "frame": launcher.isOpen ? windowRect(view.panel) : .null,
      "generation": .number(Double(model.generation)), "current": .bool(model.isCurrent),
      "error": .bool(model.rows.contains { $0.kind == .retry }),
      "placeholder": .string(view.placeholder),
      "escFrame": windowRect(view.escHint), "fieldFrame": windowRect(view.field),
      "hints": .array(view.hints.map { .string($0) }),
      "footer": [
        "origin": .string(view.footerCaption?.host ?? ""),
        "security": .string(view.footerCaption?.security.rawValue ?? ""),
        "pageIncluded": .bool(view.pageIncluded),
        "text": .string(view.origin.stringValue), "frame": windowRect(view.origin),
      ],
      "composing": .bool(editor?.hasMarkedText() ?? false),
      "runs": .number(Double(runs.runs.count)),
    ]
  }
}

extension AppController {
  func phoneState() -> JSON {
    guard let root, let window else { return .null }
    let chip = root.phoneChip
    let button = chip.disconnect
    let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    return [
      "connected": .bool(events.phoneConnected),
      "sessions": events.sessions()["sessions"] ?? [],
      "visible": .bool(!chip.isHiddenOrHasHiddenAncestor),
      "opacity": .number(Double(chip.layer?.opacity ?? 0)),
      "frame": windowRect(chip),
      "insideWindow": .bool(root.bounds.contains(chip.frame)),
      "label": .string(chip.accessibilityLabel() ?? ""),
      "button": [
        "frame": windowRect(button), "label": .string(button.accessibilityLabel() ?? ""),
        "hittable": .bool(
          !button.isHiddenOrHasHiddenAncestor
            && window.contentView?.superview?.hitTest(center) === button),
        "font": .string(button.labelFont?.fontName ?? ""),
      ],
    ]
  }
}
