import CoreGraphics

/// Where the launcher panel sits, in window coordinates with the origin at the top left. The
/// panel's top is fixed, so it does not jump when the first key adds rows. `scale` is the text
/// scale: the field, sections, rows and footer grow with it, the padding and border do not.
public enum LauncherGeometry {
  public static let width = 760.0
  public static let margin = 24.0
  public static let top = 122.0
  /// The Figma panel (760 x 630 at 1440 x 900): a longer list scrolls inside it.
  public static let maxHeight = 630.0
  public static let border = 1.0
  public static let padding = 16.0
  public static let fieldHeight = 80.0
  public static let sectionHeight = 28.0
  public static let rowHeight = 64.0
  public static let footerHeight = 48.0
  /// The compact ⌘T chip sits 20 pt above the window's bottom edge and is 40 pt tall.
  static let chipHeight = 40.0
  static let chipBottom = 20.0
  static let chipGap = 12.0
  /// A scrolling list never shrinks below one row.
  static let minimumList = rowHeight

  static func chrome(_ scale: Double) -> Double {
    border * 2 + padding * 2 + (fieldHeight + footerHeight) * scale
  }

  public static func panelWidth(window: CGSize) -> Double {
    min(width, window.width - margin * 2)
  }

  public static func listHeight(sections: Int, rows: Int, scale: Double = 1) -> Double {
    (Double(sections) * sectionHeight + Double(rows) * rowHeight) * scale
  }

  /// The panel, and how much of the list it shows. A list taller than the panel scrolls inside
  /// it, with the field and the footer pinned. The panel keeps 24 pt from the top and stays
  /// clear of the chip.
  public static func panel(window: CGSize, listHeight: Double, scale: Double = 1) -> (
    frame: CGRect, shown: Double
  ) {
    let chrome = chrome(scale)
    let reserve = chipHeight * scale + chipBottom + chipGap
    let room = max(minimumList * scale, window.height - margin - reserve - chrome)
    let shown = min(listHeight, room, max(minimumList * scale, maxHeight - chrome))
    let height = chrome + shown
    let wide = panelWidth(window: window)
    let y = max(margin, min(top, window.height - reserve - height))
    let x = ((window.width - wide) / 2).rounded()
    return (CGRect(x: x, y: y, width: wide, height: height), shown)
  }
}
