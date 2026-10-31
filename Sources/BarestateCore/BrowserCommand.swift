/// Everything the launcher, the menus and the shortcuts can ask the browser to do. The app runs
/// each case through one function, and `availability` is the only place that decides whether it
/// can run right now and why not.
public enum BrowserCommand: String, CaseIterable, Sendable {
  case back, forward, reload, history, settings
  case showOverview, focusPage, zoomIn, zoomOut, zoomToFit
  case find, closePage, reopenClosed
  case stopRun, showRunActivity
  case disconnectPhone

  public enum Presentation: String, Sendable {
    case overview, focused
  }

  public enum Availability: Equatable, Sendable {
    case enabled
    case disabled(String)
  }

  /// What `availability` reads. `presentation` is nil and `activityView` false until those
  /// surfaces exist, so their commands explain themselves instead of doing nothing.
  public struct Context: Equatable, Sendable {
    public var hasPage = false
    /// A tab is open, even a blank one: it can be closed though there is nothing to reload.
    public var hasTab = false
    /// The overview has a node to show: the selection, which starts as the active page.
    public var hasNode = false
    public var canGoBack = false
    public var canGoForward = false
    public var hasClosedPage = false
    public var presentation: Presentation?
    public var activityView = false
    public var activeRun: Run?
    public var hasRuns = false
    public var phoneConnected = false

    public init() {}
  }

  public func title(in context: Context) -> String {
    switch self {
    case .back: "Back"
    case .forward: "Forward"
    case .reload: "Reload page"
    case .history: "History"
    case .settings: "Settings"
    case .showOverview: "Show overview"
    case .focusPage: "Show page"
    case .zoomIn: "Zoom in"
    case .zoomOut: "Zoom out"
    case .zoomToFit: "Zoom to fit"
    case .find: "Find in page"
    case .closePage: "Close page"
    case .reopenClosed: "Reopen closed page"
    case .stopRun: context.activeRun.map { "Stop \($0.prompt)" } ?? "Stop task"
    case .showRunActivity: "Show Muse activity"
    case .disconnectPhone: "Disconnect phone"
    }
  }

  public var subtitle: String {
    switch self {
    case .back: "Go to the previous page"
    case .forward: "Go to the next page"
    case .reload: "Load this page again"
    case .history: "Find a page you visited"
    case .settings: "Manage browser preferences"
    case .showOverview: "See all your pages"
    case .focusPage: "Return to the current page"
    case .zoomIn: "Zoom in on the overview"
    case .zoomOut: "Zoom out"
    case .zoomToFit: "Fit every page in view"
    case .find: "Search the current page"
    case .closePage: "Close the current page"
    case .reopenClosed: "Bring back the last page you closed"
    case .stopRun: "Stop this task"
    case .showRunActivity: "See what Muse did"
    case .disconnectPhone: "Close the phone session and stop its task"
    }
  }

  /// Words that find the command besides its title.
  var keywords: String {
    switch self {
    case .back: "previous"
    case .reload: "refresh"
    case .history: "visited"
    case .settings: "preferences options"
    case .find: "search"
    case .closePage: "tab"
    case .reopenClosed: "restore tab"
    case .showOverview: "canvas"
    case .stopRun: "cancel"
    case .showRunActivity: "task"
    case .disconnectPhone: "remote mobile"
    default: ""
    }
  }

  public func availability(in context: Context) -> Availability {
    switch self {
    case .history, .settings:
      return .enabled
    case .back:
      return context.canGoBack ? .enabled : .disabled("There is no earlier page to go back to")
    case .forward:
      return context.canGoForward ? .enabled : .disabled("There is no later page to go forward to")
    case .find where context.hasPage && context.presentation == .overview:
      return .disabled("Open a page to search in it")
    case .reload, .find:
      return context.hasPage ? .enabled : .disabled("No page is open")
    case .closePage:
      return context.hasTab ? .enabled : .disabled("No page is open")
    case .reopenClosed:
      return context.hasClosedPage ? .enabled : .disabled("No closed page to reopen")
    case .showOverview:
      return view(context) { $0 == .focused ? .enabled : .disabled("Already showing the overview") }
    case .focusPage:
      return view(context) {
        if $0 == .focused { return .disabled("Already showing the page") }
        return context.hasNode ? .enabled : .disabled("No page to show")
      }
    case .zoomIn, .zoomToFit:
      return view(context) {
        $0 == .overview ? .enabled : .disabled("Zoom applies to the overview")
      }
    case .zoomOut:
      // Zooming out of a page returns to the overview.
      return view(context) { _ in .enabled }
    case .stopRun:
      return context.activeRun != nil ? .enabled : .disabled("No task is running")
    case .showRunActivity:
      if !context.activityView { return .disabled("Muse activity is not available yet") }
      return context.hasRuns ? .enabled : .disabled("No task has run yet")
    case .disconnectPhone:
      return context.phoneConnected ? .enabled : .disabled("No phone is connected")
    }
  }

  private func view(_ context: Context, _ decide: (Presentation) -> Availability) -> Availability {
    context.presentation.map(decide) ?? .disabled("The overview is not available yet")
  }
}
