import Foundation

/// What a page shows about one element and itself at one moment, as digests, so two moments can be
/// compared without keeping the page's text.
public struct PageSnapshot: Equatable, Sendable {
  public let href: String
  /// The page's visible text.
  public let page: String
  public let connected: Bool
  /// The element's tag, attributes and text.
  public let shell: String
  /// Checked, selected, open, disabled, value and the ARIA state attributes.
  public let state: String
  /// Whether the element holds focus, and whether focus is what clicking it is for (a text field).
  public let focused: Bool
  public let entry: Bool

  public init(
    href: String, page: String, connected: Bool, shell: String, state: String,
    focused: Bool = false, entry: Bool = false
  ) {
    self.href = href
    self.page = page
    self.connected = connected
    self.shell = shell
    self.state = state
    self.focused = focused
    self.entry = entry
  }

  init?(json: JSON) {
    guard let href = json["href"]?.string, let page = json["page"]?.string,
      let connected = json["connected"]?.bool, let shell = json["shell"]?.string,
      let state = json["state"]?.string
    else { return nil }
    self.init(
      href: href, page: page, connected: connected, shell: shell, state: state,
      focused: json["focused"]?.bool ?? false, entry: json["entry"]?.bool ?? false)
  }

  /// Runs with `this` bound to the element.
  static let script = #"""
    function () {
      const el = this, doc = el.ownerDocument || document;
      const digest = (text) => {
        let hash = 5381;
        for (let i = 0; i < text.length; i++) hash = (hash * 33 ^ text.charCodeAt(i)) | 0;
        return (hash >>> 0).toString(36) + ":" + text.length;
      };
      const attribute = (name) => el.getAttribute ? el.getAttribute(name) : null;
      const attributes = Array.from(el.attributes || []).map((a) => a.name + "=" + a.value)
        .sort().join(";");
      return {
        href: doc.location.href,
        page: digest(doc.body ? doc.body.innerText : ""),
        focused: doc.activeElement === el,
        entry: el.matches ? el.matches("textarea, select, [contenteditable]:not([contenteditable=false]), "
          + "input:not([type=button], [type=submit], [type=reset], [type=image], [type=checkbox], "
          + "[type=radio])") : false,
        connected: el.isConnected,
        shell: digest(el.tagName + "|" + attributes + "|" + (el.textContent || "").slice(0, 500)),
        state: [el.checked, el.selected, el.open, el.disabled, attribute("aria-expanded"),
          attribute("aria-pressed"), attribute("aria-checked"), attribute("aria-selected"),
          typeof el.value === "string" ? el.value : null].join("|"),
      };
    }
    """#
}

/// Kind-specific read-back of a write (architecture §5.7).
public enum ReadBack {
  /// The nearest effect a click had, from the one that proves most to the one that proves least.
  /// A nil `after` means the element could not be read at all.
  public static func click(
    before: PageSnapshot, after: PageSnapshot?, documentChanged: Bool
  ) -> DispatchOutcome {
    func outcome(_ verdict: String) -> DispatchOutcome {
      DispatchOutcome(verified: verdict != "unchanged", verdict: verdict)
    }
    if documentChanged { return outcome("document-changed") }
    guard let after, after.connected else { return outcome("element-gone") }
    if after.href != before.href { return outcome("url-changed") }
    if after.state != before.state { return outcome("state-changed") }
    if after.shell != before.shell { return outcome("element-changed") }
    if after.page != before.page { return outcome("page-changed") }
    if after.entry && after.focused && !before.focused { return outcome("focused") }
    return outcome("unchanged")
  }

  /// A field's value and selection, in UTF-16 units as the page counts them.
  public struct Caret: Equatable, Sendable {
    public let value: String
    public let start: Int
    public let end: Int

    public init(value: String, start: Int, end: Int) {
      self.value = value
      self.start = start
      self.end = end
    }

    public init?(json: JSON) {
      guard let value = json["value"]?.string, let start = json["start"]?.int,
        let end = json["end"]?.int
      else { return nil }
      self.init(value: value, start: start, end: end)
    }

    /// Runs with `this` bound to the field, after it has been focused.
    static let script = #"""
      function () {
        if (typeof this.value !== "string") {
          const text = this.textContent || "", selection = getSelection();
          if (selection.rangeCount && this.contains(selection.anchorNode)) {
            const range = selection.getRangeAt(0), before = document.createRange();
            before.selectNodeContents(this);
            before.setEnd(range.startContainer, range.startOffset);
            const start = before.toString().length;
            return { value: text, start, end: start + range.toString().length };
          }
          return { value: text, start: text.length, end: text.length };
        }
        const value = this.value;
        return {
          value, start: this.selectionStart ?? value.length, end: this.selectionEnd ?? value.length,
        };
      }
      """#
  }

  /// The value a field must hold after `text` is inserted at its caret, replacing any selection.
  public static func expectedValue(before: Caret, inserting text: String) -> String {
    let units = Array(before.value.utf16)
    let end = min(max(before.end, 0), units.count)
    let start = min(max(before.start, 0), end)
    return String(decoding: units[..<start] + Array(text.utf16) + units[end...], as: UTF16.self)
  }
}
