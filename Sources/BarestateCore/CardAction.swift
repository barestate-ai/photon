/// What a right-click on a page's card offers, in the order the menu lists it.
public enum CardAction: String, CaseIterable, Sendable {
  case open, maximize
  case closePage = "close-page"

  public var title: String {
    switch self {
    case .open: "Open"
    case .maximize: "Maximize"
    case .closePage: "Close Page"
    }
  }

  /// A closed page's card has no browser to close.
  public func isAvailable(live: Bool) -> Bool { self != .closePage || live }
}
