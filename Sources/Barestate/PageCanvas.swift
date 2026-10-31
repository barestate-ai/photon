import BarestateCore
import Foundation

/// Owns the page graph. Tab events change it on the main actor; it is saved through the Store a
/// moment after it stops changing, so a drag or a pan never writes per pointer event.
@MainActor
final class PageCanvas {
  static let saveDelay = Duration.milliseconds(600)

  private(set) var graph = PageGraph()
  var previews = PreviewCache()
  private var saved = PageGraph()
  private var timer: Task<Void, Never>?
  private var gesturing = false
  private var writing: Task<Void, Never>?
  private let store: @MainActor () -> Store?
  /// Called after the graph or the previews changed, for the overview to draw.
  var changed: (() -> Void)?

  init(store: @escaping @MainActor () -> Store?) {
    self.store = store
  }

  func restore(_ graph: PageGraph) {
    self.graph = graph
    saved = graph
  }

  /// Applies `change`; it returns whether the graph changed, which is what schedules a save.
  func edit(_ change: (inout PageGraph) -> Bool) {
    guard change(&graph) else { return }
    previews.retain(Set(graph.nodes.map(\.id)))
    scheduleSave()
    changed?()
  }

  func tabChanged(_ tab: Tab) {
    edit { graph in
      let changed = graph.observe(
        tab: tab.id, url: tab.url, title: tab.title, origin: tab.origin,
        now: Date().timeIntervalSince1970)
      // The origin only decides how a node is first created.
      if graph.nodeId(forTab: tab.id) != nil { tab.origin = .none }
      return changed
    }
  }

  func tabClosed(_ id: String) {
    edit { $0.close(tab: id, now: Date().timeIntervalSince1970) }
  }

  /// The origin of a tab opened from `tab`: an edge only if that page is a node.
  func origin(from tab: Tab?, _ kind: EdgeKind) -> NewTabOrigin {
    guard let tab, let node = graph.nodeId(forTab: tab.id) else { return .none }
    return .from(node: node, kind: kind)
  }

  /// A drag, pan or zoom holds the save back until it ends, however long it pauses.
  func gesture(_ active: Bool) {
    gesturing = active
    if active { timer?.cancel() } else if graph != saved { scheduleSave() }
  }

  private func scheduleSave() {
    timer?.cancel()
    guard !gesturing else { return }
    timer = Task { [weak self] in
      do { try await Task.sleep(for: Self.saveDelay) } catch { return }
      self?.save()
    }
  }

  private func save() {
    guard graph != saved, let store = store() else { return }
    saved = graph
    let (snapshot, previous) = (graph, writing)
    // Detached: quitting waits for this write while the main thread is blocked, so it must not
    // need the main actor to finish. The next change saves the whole graph again.
    writing = Task.detached {
      await previous?.value
      do {
        try await store.saveCanvas(snapshot)
      } catch {
        Log.error(.store, "canvas save failed: \(Log.describe(error))")
      }
    }
  }

  /// What quitting must still write, as a closure the message loop's end can await off the main
  /// actor.
  func finish() -> @Sendable () async -> Void {
    timer?.cancel()
    let (pending, writes, store) = (graph != saved ? graph : nil, writing, store())
    return {
      await writes?.value
      guard let pending, let store else { return }
      do {
        try await store.saveCanvas(pending)
      } catch {
        Log.error(.store, "canvas save failed: \(Log.describe(error))")
      }
    }
  }
}
