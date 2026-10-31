import BarestateCore
import Testing

struct PageGraphTests {
  private func open(
    _ graph: inout PageGraph, _ tab: String, from: String? = nil, at now: Double = 1
  ) {
    let origin: NewTabOrigin = from.map { .from(node: $0, kind: .openedFrom) } ?? .none
    _ = graph.observe(tab: tab, url: "https://\(tab).test/", title: tab, origin: origin, now: now)
  }

  @Test func blankAndErrorPagesNeverBecomeNodes() {
    var graph = PageGraph()
    for url in ["", "about:blank", "chrome-error://chromewebdata/"] {
      let r1 = graph.observe(tab: "t1", url: url, title: "", origin: .none, now: 1)
      #expect(!r1)
    }
    #expect(graph.nodes.isEmpty)
  }

  @Test func aTabThatGoesBlankArchivesItsPageAndAnErrorPageChangesNothing() throws {
    var graph = PageGraph()
    open(&graph, "t1")
    let errored = graph.observe(
      tab: "t1", url: "chrome-error://chromewebdata/", title: "", origin: .none, now: 2)
    #expect(!errored)
    #expect(graph.nodes.first?.tabId == "t1")
    let blanked = graph.observe(tab: "t1", url: "about:blank", title: "", origin: .none, now: 3)
    #expect(blanked)
    #expect(graph.nodes.count == 1)
    #expect(try #require(graph.nodes.first).isArchived)
    #expect(graph.nodes.first?.url == "https://t1.test/")
  }

  @Test func aCommittedPageIsOneLiveNodeThatFollowsItsTab() throws {
    var graph = PageGraph()
    let r2 = graph.observe(tab: "t1", url: "https://a.test/", title: "A", origin: .none, now: 1)
    #expect(r2)
    let r3 = graph.observe(tab: "t1", url: "https://a.test/", title: "A", origin: .none, now: 2)
    #expect(!r3)
    let r4 = graph.observe(
      tab: "t1", url: "https://a.test/next", title: "Next", origin: .none, now: 3)
    #expect(r4)
    #expect(graph.nodes.count == 1)
    let node = try #require(graph.nodes.first)
    #expect(node.tabId == "t1" && node.url == "https://a.test/next" && node.title == "Next")
    #expect(graph.nodeId(forTab: "t1") == node.id)
  }

  @Test func closingKeepsTheNodeArchivedWhereItWas() throws {
    var graph = PageGraph()
    open(&graph, "t1")
    let before = try #require(graph.nodes.first)
    let r5 = graph.close(tab: "t1", now: 5)
    #expect(r5)
    let after = try #require(graph.nodes.first)
    #expect(after.tabId == nil && after.isArchived)
    #expect(after.url == before.url && after.x == before.x && after.y == before.y)
    #expect(graph.nodeId(forTab: "t1") == nil)
    let r6 = graph.close(tab: "t1", now: 6)
    #expect(!r6)
  }

  @Test func onlyTheFortyMostRecentlyClosedPagesStayAndTheirEdgesGo() {
    var graph = PageGraph()
    open(&graph, "root")
    let root = graph.nodeId(forTab: "root")!
    for n in 1...45 {
      open(&graph, "p\(n)", from: root, at: Double(n))
      let r7 = graph.close(tab: "p\(n)", now: Double(n))
      #expect(r7)
    }
    let archived = graph.nodes.filter(\.isArchived)
    #expect(archived.count == PageGraph.archiveLimit)
    #expect(graph.nodes.count == 41)
    #expect(!archived.contains { $0.url == "https://p5.test/" })
    #expect(archived.contains { $0.url == "https://p6.test/" })
    #expect(graph.edges.count == 40)
    #expect(graph.edges.allSatisfy { edge in graph.nodes.contains { $0.id == edge.to } })
  }

  @Test func reopeningAnArchivedNodeMakesItLiveAgainWithoutADuplicate() throws {
    var graph = PageGraph()
    open(&graph, "t1")
    open(&graph, "t2")
    let closed = try #require(graph.nodeId(forTab: "t1"))
    let position = try #require(graph.nodes.first { $0.id == closed })
    _ = graph.close(tab: "t1", now: 2)
    #expect(graph.lastArchivedId(url: "https://t1.test/") == closed)
    let r8 = graph.observe(
      tab: "t3", url: "https://t1.test/", title: "t1", origin: .reopen(node: closed), now: 3)
    #expect(r8)
    #expect(graph.nodes.count == 2)
    let revived = try #require(graph.nodes.first { $0.id == closed })
    #expect(revived.tabId == "t3" && revived.x == position.x && revived.y == position.y)
  }

  @Test func aReopenOfAMissingNodeIsJustANewPage() {
    var graph = PageGraph()
    _ = graph.observe(
      tab: "t1", url: "https://a.test/", title: "", origin: .reopen(node: "n99"), now: 1)
    #expect(graph.nodes.count == 1)
  }

  @Test func anEdgeComesOnlyFromTheOriginGivenWhenTheNodeIsFirstCommitted() throws {
    var graph = PageGraph()
    open(&graph, "a")
    let a = try #require(graph.nodeId(forTab: "a"))
    open(&graph, "b", from: a)
    let b = try #require(graph.nodeId(forTab: "b"))
    _ = graph.observe(
      tab: "b", url: "https://b.test/x", title: "", origin: .from(node: a, kind: .openedFrom),
      now: 2)
    #expect(graph.edges == [PageEdge(from: a, to: b, kind: .openedFrom)])
    open(&graph, "c")
    open(&graph, "d", from: "n99")
    #expect(graph.edges.count == 1)
  }

  @Test func launcherNavigationEdgesAreTheirOwnKind() throws {
    var graph = PageGraph()
    open(&graph, "a")
    let a = try #require(graph.nodeId(forTab: "a"))
    _ = graph.observe(
      tab: "b", url: "https://b.test/", title: "", origin: .from(node: a, kind: .navigatedFrom),
      now: 2)
    #expect(graph.edges.map(\.kind) == [.navigatedFrom])
  }

  @Test func edgesSurviveEitherPageClosing() throws {
    var graph = PageGraph()
    open(&graph, "a")
    open(&graph, "b", from: graph.nodeId(forTab: "a"))
    _ = graph.close(tab: "a", now: 3)
    _ = graph.close(tab: "b", now: 4)
    #expect(graph.edges.count == 1)
  }

  @Test func museUsedIsRecordedOncePerRunFromOwnerToUsedPage() throws {
    var graph = PageGraph()
    open(&graph, "a")
    open(&graph, "b")
    let (a, b) = (try #require(graph.nodeId(forTab: "a")), try #require(graph.nodeId(forTab: "b")))
    let r9 = graph.museUsed(run: "r1", ownerTab: "a", usedTab: "b")
    #expect(r9)
    let r10 = graph.museUsed(run: "r1", ownerTab: "a", usedTab: "b")
    #expect(!r10)
    let r11 = graph.museUsed(run: "r2", ownerTab: "a", usedTab: "b")
    #expect(r11)
    let r12 = graph.museUsed(run: "r3", ownerTab: "a", usedTab: "a")
    #expect(!r12)
    let r13 = graph.museUsed(run: "r3", ownerTab: "a", usedTab: "gone")
    #expect(!r13)
    #expect(
      graph.edges == [
        PageEdge(from: a, to: b, kind: .museUsed, runId: "r1"),
        PageEdge(from: a, to: b, kind: .museUsed, runId: "r2"),
      ])
  }

  @Test func theFirstSlotAroundASourceFollowsTheRingClockwiseFromTheEast() {
    let step = (x: PageGraph.slotWidth, y: PageGraph.slotHeight)
    let source = CanvasPoint(x: 100, y: 50)
    var occupied = [source]
    var slots: [CanvasPoint] = []
    for _ in 0..<4 {
      let slot = PageGraph.place(near: source, occupied: occupied)
      slots.append(slot)
      occupied.append(slot)
    }
    #expect(slots[0] == CanvasPoint(x: 100 + step.x, y: 50))
    #expect(slots[1] == CanvasPoint(x: 100 + step.x, y: 50 + step.y))
    #expect(slots[2] == CanvasPoint(x: 100, y: 50 + step.y))
    #expect(slots[3] == CanvasPoint(x: 100 - step.x, y: 50 + step.y))
  }

  @Test func neighbouringSlotsLeaveRoomForATrailBetweenCards() {
    #expect(PageGraph.slotWidth - PageGraph.nodeWidth >= 80)
    #expect(PageGraph.slotHeight - PageGraph.nodeHeight >= 56)
  }

  @Test func ringsWidenOnceTheInnerOnesAreFull() {
    let source = CanvasPoint(x: 0, y: 0)
    var occupied = [source]
    for _ in 0..<8 { occupied.append(PageGraph.place(near: source, occupied: occupied)) }
    let ninth = PageGraph.place(near: source, occupied: occupied)
    #expect(ninth == CanvasPoint(x: 2 * PageGraph.slotWidth, y: 0))
  }

  @Test func withoutASourceTheCentroidIsTheAnchor() {
    #expect(PageGraph.place(near: nil, occupied: []) == CanvasPoint(x: 0, y: 0))
    let occupied = [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1000, y: 1000)]
    let slot = PageGraph.place(near: nil, occupied: occupied)
    #expect(slot == CanvasPoint(x: 500, y: 500))
  }

  @Test func theSameSequenceAlwaysGivesTheSamePositionsAndNothingOverlaps() throws {
    func build() -> PageGraph {
      var graph = PageGraph()
      for n in 1...5 { open(&graph, "r\(n)") }
      let two = graph.nodeId(forTab: "r2")
      for n in 1...3 { open(&graph, "a\(n)", from: two) }
      let five = graph.nodeId(forTab: "r5")
      for n in 1...2 { open(&graph, "b\(n)", from: five) }
      return graph
    }
    let (one, other) = (build(), build())
    #expect(one.nodes.map { [$0.x, $0.y] } == other.nodes.map { [$0.x, $0.y] })
    #expect(one.nodes.count == 10)
    for (i, a) in one.nodes.enumerated() {
      for b in one.nodes[(i + 1)...] {
        #expect(abs(a.x - b.x) >= PageGraph.slotWidth || abs(a.y - b.y) >= PageGraph.slotHeight)
      }
    }
  }

  @Test func aPlacedNodeOnlyMovesWhenItIsDragged() throws {
    var graph = PageGraph()
    open(&graph, "a")
    open(&graph, "b")
    let before = graph.nodes
    open(&graph, "c")
    _ = graph.close(tab: "c", now: 9)
    #expect(Array(graph.nodes.prefix(2)).map { [$0.x, $0.y] } == before.map { [$0.x, $0.y] })
    let a = try #require(graph.nodeId(forTab: "a"))
    let r14 = graph.move(node: a, to: CanvasPoint(x: 7, y: 8))
    #expect(r14)
    let r15 = graph.move(node: a, to: CanvasPoint(x: 7, y: 8))
    #expect(!r15)
    let r16 = graph.move(node: "n99", to: CanvasPoint(x: 1, y: 1))
    #expect(!r16)
    #expect(graph.nodes.first { $0.id == a }.map { [$0.x, $0.y] } == [7, 8])
    #expect(graph.nodes[1].x == before[1].x)
  }

  @Test func restoringTurnsEveryNodeIntoAnArchivedOneAtItsSavedPosition() throws {
    var graph = PageGraph()
    open(&graph, "a")
    open(&graph, "b", from: graph.nodeId(forTab: "a"))
    let restored = PageGraph(
      restoring: graph.nodes, edges: graph.edges, title: "Trip",
      viewport: Viewport(cx: 3, cy: 4, zoom: 0.5))
    #expect(restored.nodes.allSatisfy { $0.isArchived })
    #expect(restored.nodes.map { [$0.x, $0.y] } == graph.nodes.map { [$0.x, $0.y] })
    #expect(restored.edges == graph.edges)
    #expect(restored.title == "Trip" && restored.viewport.zoom == 0.5)
    var next = restored
    open(&next, "c")
    #expect(Set(next.nodes.map(\.id)).count == 3)
  }

  @Test func restoringDropsEdgesWithAMissingEndAndTrimsTheArchive() {
    let nodes = (1...45).map {
      PageNode(
        id: "n\($0)", tabId: nil, url: "https://p\($0).test/", title: "", x: Double($0) * 300, y: 0,
        updatedAt: Double($0))
    }
    let edges = [
      PageEdge(from: "n1", to: "n45", kind: .openedFrom),
      PageEdge(from: "n44", to: "n45", kind: .openedFrom),
      PageEdge(from: "n44", to: "n99", kind: .openedFrom),
    ]
    let graph = PageGraph(restoring: nodes, edges: edges, title: "", viewport: Viewport())
    #expect(graph.nodes.count == 40)
    #expect(graph.edges == [PageEdge(from: "n44", to: "n45", kind: .openedFrom)])
    #expect(graph.title == PageGraph.defaultTitle)
  }

  @Test func theTitleDefaultsAndTheZoomStaysInRange() {
    var graph = PageGraph()
    #expect(graph.title == "Your pages")
    graph.setTitle("  Trip planning ")
    #expect(graph.title == "Trip planning")
    graph.setTitle("   ")
    #expect(graph.title == "Your pages")
    #expect(Viewport(cx: 0, cy: 0, zoom: 99).zoom == 1.5)
    #expect(Viewport(cx: 0, cy: 0, zoom: 0).zoom == 0.2)
    #expect(Viewport(cx: 0, cy: 0, zoom: .nan).zoom == 1)
  }
}
