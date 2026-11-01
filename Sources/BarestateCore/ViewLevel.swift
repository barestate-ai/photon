/// How much of the window a page has: the overview of every page, one page in its context, or the
/// page filling the window. Full window is a state of the focused page, not a fourth place to be.
public enum ViewLevel: String, Sendable, Equatable {
  case overview, focused
  case fullWindow = "full-window"

  public init(_ presentation: BrowserCommand.Presentation, fillsWindow: Bool) {
    switch presentation {
    case .overview: self = .overview
    case .focused: self = fillsWindow ? .fullWindow : .focused
    }
  }

  /// One step toward the overview: what a pinch out or zooming out does.
  public var steppedOut: ViewLevel {
    self == .fullWindow ? .focused : .overview
  }

  /// ⌘↩ leaves Full window, opens the focused page in it, or opens the selected card from the
  /// overview.
  public func canToggleFullWindow(hasSelection: Bool) -> Bool {
    self != .overview || hasSelection
  }
}
