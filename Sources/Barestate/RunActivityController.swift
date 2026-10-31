import AppKit
import BarestateCore

/// Drives the run activity view: which task it shows and when it redraws. The view only draws
/// what `RunActivity` says, so it always equals `run.list` and the pending approvals.
@MainActor
final class RunActivityController {
  private unowned let app: AppController
  private(set) var runId: String?

  init(app: AppController) {
    self.app = app
  }

  private var view: RunActivityView? { app.root?.activity }
  var isOpen: Bool { runId != nil }

  func wire(_ view: RunActivityView) {
    view.onStop = { [weak self] in self?.stop() }
    view.onClose = { [weak self] in self?.close() }
    app.viewsById["runActivity"] = view.panel
    app.viewsById["runActivityStop"] = view.stop
    app.viewsById["runActivityClose"] = view.close
  }

  /// The task asked for, else the one in progress, else the newest; nothing to show before any
  /// task started.
  func open(_ id: String? = nil) {
    guard let view, let run = id.flatMap(app.runs.run) ?? RunActivity.subject(in: app.runs.runs)
    else { return }
    if isOpen {
      runId = run.id
      return refresh()
    }
    runId = run.id
    view.show(content(run))
    view.appear()
    app.window?.makeFirstResponder(view.stop.isEnabled ? view.stop : view.close)
  }

  func close() {
    guard isOpen, let view else { return }
    runId = nil
    view.hide()
    if let tab = app.activeTab {
      app.pageFocus(tab)
    } else {
      app.window?.makeFirstResponder(app.root)
    }
  }

  func refresh() {
    guard let view, let run = runId.flatMap(app.runs.run) else { return }
    view.render(content(run))
    if view.window?.firstResponder === view.stop, !view.stop.isEnabled {
      app.window?.makeFirstResponder(view.close)
    }
  }

  /// Ends the task shown, from the view's Stop button.
  private func stop() {
    guard let id = runId else { return }
    _ = try? app.runs.stop(id)
  }

  /// What the view shows right now.
  var shown: RunActivity? { runId.flatMap(app.runs.run).map(content) }

  private func content(_ run: Run) -> RunActivity {
    let session = app.runs.session(run.id)
    return RunActivity(
      run, pages: Dictionary(uniqueKeysWithValues: app.tabs.map { ($0.id, app.displayTitle($0)) }),
      waiting: app.approvals.items.filter { $0.sessionId == session }.map(\.text))
  }
}

// MARK: Test state

@MainActor
extension AppController {
  func activityState() -> JSON {
    guard let view = root?.activity else { return .null }
    guard let shown = activity.shown else { return ["open": false] }
    func button(_ control: ApprovalButton) -> JSON {
      [
        "label": .string(control.accessibilityLabel() ?? ""), "enabled": .bool(control.isEnabled),
        "focused": .bool(window?.firstResponder === control), "frame": windowRect(control),
      ]
    }
    return [
      "open": true, "runId": .string(shown.runId), "prompt": .string(shown.prompt),
      "status": .string(shown.status), "reason": shown.reason.map { .string($0) } ?? .null,
      "entries": .array(
        shown.entries.map {
          ["id": .number(Double($0.id)), "text": .string($0.text), "detail": .string($0.detail)]
        }),
      "waiting": .array(shown.waiting.map { .string($0) }),
      "stop": button(view.stop), "close": button(view.close), "frame": windowRect(view.panel),
    ]
  }
}
