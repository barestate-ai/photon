import CoreGraphics
import Testing

@testable import BarestateCore

@Suite struct FocusLayoutTests {
  private let desktop = CGSize(width: 1440, height: 900)

  @Test func theCardAndColumnsMatchTheFocusedFrameAtDesktopSize() {
    let layout = FocusLayout.make(size: desktop, left: 2, right: 2)
    #expect(layout.columns)
    #expect(layout.card.width == 632)
    #expect(abs(layout.card.height - 532) <= 1)
    #expect(abs(layout.card.minX - 468) <= 1)
    #expect(layout.card.minY == 208)
    #expect(layout.left.map(\.width) == [252, 252])
    #expect(layout.right.map(\.width) == [200, 200])
    #expect(layout.left.allSatisfy { $0.maxX < layout.card.minX })
    #expect(layout.right.allSatisfy { $0.minX > layout.card.maxX })
  }

  @Test func aPageWithoutNeighboursIsCentredWithNoColumns() {
    let layout = FocusLayout.make(size: desktop, left: 0, right: 0)
    #expect(!layout.columns)
    #expect(layout.card.width == 632)
    #expect(layout.card.midX == 720)
    #expect(layout.left.isEmpty && layout.right.isEmpty)
  }

  @Test func columnsCollapseBelow1100AndMarginsAreEqualAndSmall() {
    for width in [1099.0, 1000, 720] {
      let layout = FocusLayout.make(size: CGSize(width: width, height: 700), left: 3, right: 3)
      #expect(!layout.columns)
      #expect(layout.left.isEmpty && layout.right.isEmpty)
      #expect(layout.card.minX == 24)
      #expect(layout.card.maxX == CGFloat(width) - 24)
    }
    #expect(FocusLayout.make(size: CGSize(width: 1100, height: 700), left: 1, right: 0).columns)
  }

  @Test func theCaptionSitsJustBelowTheCardAndClearOfTheCommandButton() {
    for size in [desktop, CGSize(width: 720, height: 600), CGSize(width: 1100, height: 760)] {
      let layout = FocusLayout.make(size: size, left: 1, right: 1)
      #expect(layout.caption.minY == layout.card.maxY + 4)
      #expect(layout.caption.maxY <= size.height - 16 - 48)
      #expect(layout.card.minY >= 96)
    }
  }

  @Test func columnsKeepOnlyWhatFitsAboveTheCommandButton() {
    let layout = FocusLayout.make(size: desktop, left: 9, right: 9)
    #expect(layout.left.count < 9 && layout.right.count < 9)
    for slot in layout.left + layout.right { #expect(slot.maxY <= 900 - 16 - 48) }
    for pair in [layout.left, layout.right] {
      #expect(pair.count == Set(pair.map(\.minY)).count)
    }
  }

  @Test func noCardOverlapsTheLiveCardAtAnyWidth() {
    for width in stride(from: 1100.0, through: 2400, by: 100) {
      let layout = FocusLayout.make(size: CGSize(width: width, height: 900), left: 3, right: 3)
      for slot in layout.left + layout.right { #expect(!slot.intersects(layout.card)) }
    }
  }

  @Test func theContextOfAPageIsItsEdgeNeighboursSplitByWhichSideTheyLieOn() {
    var graph = PageGraph()
    graph.observe(tab: "a", url: "https://a.test/", title: "A", origin: .none, now: 1)
    graph.observe(
      tab: "b", url: "https://b.test/", title: "B", origin: .from(node: "n1", kind: .openedFrom),
      now: 2)
    graph.observe(
      tab: "c", url: "https://c.test/", title: "C", origin: .from(node: "n1", kind: .openedFrom),
      now: 3)
    graph.observe(tab: "d", url: "https://d.test/", title: "D", origin: .none, now: 4)
    let focus = graph.nodes[0]
    let context = graph.context(of: focus.id)
    let all = (context.left + context.right).map(\.id)
    #expect(Set(all) == ["n2", "n3"])
    #expect(context.left.allSatisfy { $0.x < focus.x })
    #expect(context.right.allSatisfy { $0.x >= focus.x })
    #expect(graph.context(of: "n4").left.isEmpty && graph.context(of: "n4").right.isEmpty)
    #expect(graph.context(of: "n2").left.count + graph.context(of: "n2").right.count == 1)
  }
}
