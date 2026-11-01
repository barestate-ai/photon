import AppKit

/// `BarestateApplication.performShortcut` runs every exact match first, so whatever still reaches
/// AppKit's own search is a near miss (Cmd-Shift-L would run Cmd-L) and must do nothing.
final class ExactKeyMenu: NSMenu {
  override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// Every shortcut is a menu key equivalent, so AppKit routes it once, whether focus is in the
/// launcher, the find bar or a page.
@MainActor
func makeMainMenu(controller: AppController) -> NSMenu {
  let main = ExactKeyMenu()

  func add(
    _ title: String, _ menu: NSMenu, _ action: Selector?, _ key: String,
    _ mask: NSEvent.ModifierFlags = .command, target: AnyObject? = controller, tag: Int = 0
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = mask
    item.target = target
    item.tag = tag
    menu.addItem(item)
  }

  func submenu(_ title: String, _ build: (NSMenu) -> Void) {
    let item = NSMenuItem()
    let menu = NSMenu(title: title)
    build(menu)
    item.submenu = menu
    main.addItem(item)
  }

  submenu("Photon") { menu in
    add("About Photon", menu, #selector(AppController.showAbout), "", [])
    menu.addItem(.separator())
    add("Settings…", menu, #selector(AppController.showSettings), ",")
    menu.addItem(.separator())
    add("Hide Photon", menu, #selector(NSApplication.hide(_:)), "h", target: NSApp)
    add(
      "Hide Others", menu, #selector(NSApplication.hideOtherApplications(_:)), "h",
      [.command, .option], target: NSApp)
    menu.addItem(.separator())
    add("Quit Photon", menu, #selector(NSApplication.terminate(_:)), "q", target: NSApp)
  }
  submenu("File") { menu in
    add("New Tab", menu, #selector(AppController.newTab), "t")
    add("Open Location…", menu, #selector(AppController.openLocation), "l")
    add("Close Tab", menu, #selector(AppController.closeActiveTab), "w")
    add(
      "Reopen Closed Tab", menu, #selector(AppController.reopenClosedTab), "T", [.command, .shift])
    menu.addItem(.separator())
    add("Bookmark This Page", menu, #selector(AppController.bookmarkPage), "d")
  }
  submenu("Edit") { menu in
    add("Undo", menu, #selector(AppController.undoEdit), "z")
    add("Redo", menu, #selector(AppController.redoEdit), "Z", [.command, .shift])
    menu.addItem(.separator())
    add("Cut", menu, #selector(AppController.cutEdit), "x")
    add("Copy", menu, #selector(AppController.copyEdit), "c")
    add("Paste", menu, #selector(AppController.pasteEdit), "v")
    add("Select All", menu, #selector(AppController.selectAllEdit), "a")
    menu.addItem(.separator())
    add("Find in Page…", menu, #selector(AppController.showFind), "f")
  }
  submenu("View") { menu in
    add("Reload Page", menu, #selector(AppController.reloadPage), "r")
    menu.addItem(.separator())
    add("Show Page", menu, #selector(AppController.toggleOverview), "\\", [.command, .shift])
    add("Open Full Window", menu, #selector(AppController.toggleFullWindow), "\r")
    menu.addItem(.separator())
    add("Zoom In", menu, #selector(AppController.zoomInOverview), "=")
    add("Zoom Out", menu, #selector(AppController.zoomOutOverview), "-")
    add("Zoom to Fit", menu, #selector(AppController.zoomToFitOverview), "0")
    menu.addItem(.separator())
    add(
      "Enter Full Screen", menu, #selector(AppController.toggleNativeFullScreen), "f",
      [.command, .control])
  }
  submenu("Muse") { menu in
    add("Show Muse Activity", menu, #selector(AppController.showMuseActivity), "", [])
    add("Stop Task", menu, #selector(AppController.stopTask), "", [])
  }
  submenu("History") { menu in
    add("Back", menu, #selector(AppController.goBack), "[")
    add("Forward", menu, #selector(AppController.goForward), "]")
  }
  submenu("Tab") { menu in
    add("Show Next Tab", menu, #selector(AppController.selectNextTab), "\t", .control)
    add(
      "Show Previous Tab", menu, #selector(AppController.selectPreviousTab), "\u{19}",
      [.control, .shift])
    menu.addItem(.separator())
    for number in 1...8 {
      add(
        "Select Tab \(number)", menu, #selector(AppController.selectTabByNumber(_:)),
        String(number), tag: number)
    }
    add("Select Last Tab", menu, #selector(AppController.selectTabByNumber(_:)), "9", tag: 9)
  }
  return main
}

extension NSMenu {
  /// The enabled item whose key equivalent this event triggers, searching submenus.
  func item(matching event: NSEvent) -> NSMenuItem? {
    let wanted: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
    let flags = event.modifierFlags.intersection(wanted)
    var characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
    // A keyboard reports Shift with a backslash as the bar.
    if characters == "|" { characters = "\\" }
    for item in items {
      if let submenu = item.submenu, let found = submenu.item(matching: event) { return found }
      if !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == characters,
        item.keyEquivalentModifierMask.intersection(wanted) == flags
      {
        return item
      }
    }
    return nil
  }
}
