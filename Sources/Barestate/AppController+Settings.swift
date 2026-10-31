import AppKit
import BarestateCore

/// The Settings window and the preferences it edits.
@MainActor
extension AppController {
  /// Animations are skipped when the system or a test asks for reduced motion.
  var motionReduced: Bool {
    reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func setSearchEngine(_ template: String) {
    settings.searchEngine = template
    saveSettings()
    settingsWindow?.refresh()
  }

  @objc func showSettings() {
    let window = settingsWindow ?? SettingsWindow(controller: self)
    if settingsWindow == nil {
      settingsWindow = window
      for (id, view) in window.controlsById { viewsById[id] = view }
    }
    window.show()
  }

  private func saveSettings() {
    do {
      try settings.save(path: dataDir.settings)
    } catch {
      Log.error(.engine, "settings save failed: \(Log.describe(error))")
    }
  }

  /// AppKit asks just before it shows a menu. Bookmarking needs a page worth remembering, and the
  /// item says so in its tooltip instead of silently doing nothing. Editing needs a text
  /// responder or a focused page.
  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let enabled = menuItemEnabled(item)
    guard launcher.isOpen, let action = item.action else { return enabled }
    return enabled && launcher.allows(action, target: item.target)
  }

  private func menuItemEnabled(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(bookmarkPage):
      let recordable = activeTab.map { AddressInput.isRecordable($0.url) } ?? false
      item.toolTip = recordable ? nil : "Open a page to bookmark it"
      return recordable
    case #selector(undoEdit), #selector(redoEdit), #selector(cutEdit), #selector(copyEdit),
      #selector(pasteEdit), #selector(selectAllEdit):
      let target = settingsWindow?.isFront == true ? settingsWindow?.window : window
      let responder = target?.firstResponder
      return responder is NSText
        || BarestateApplication.tabId(containing: responder as? NSView) != nil
    default:
      return validateCommandItem(item)
    }
  }
}
