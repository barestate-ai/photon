import CoreGraphics
import Foundation
import Testing

@testable import BarestateCore

private let size = CGSize(width: 1440, height: 900)

private func node(_ id: String, _ x: Double, _ y: Double) -> PageNode {
  PageNode(id: id, tabId: id, url: "https://\(id).test/", title: id, x: x, y: y)
}

@Suite struct ViewportGeometryTests {
  @Test func screenAndCanvasPointsRoundTrip() {
    let view = Viewport(cx: 120, cy: -40, zoom: 0.5)
    let point = CGPoint(x: 333, y: 77)
    let back = view.canvas(view.screen(point, in: size), in: size)
    #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    #expect(view.screen(CGPoint(x: 120, y: -40), in: size) == CGPoint(x: 720, y: 450))
  }

  @Test func panMovesTheCentreByTheScreenDeltaOverZoom() {
    let view = Viewport(cx: 10, cy: 20, zoom: 0.5)
    let moved = view.panned(byScreen: CGSize(width: 30, height: -10))
    #expect(moved.cx == 10 - 60 && moved.cy == 20 + 20)
    let home = moved.panned(byScreen: CGSize(width: -30, height: 10))
    #expect(home == view)
  }

  @Test func zoomKeepsTheCanvasPointUnderThePointerStill() {
    let view = Viewport(cx: 50, cy: 80, zoom: 1)
    let pointer = CGPoint(x: 300, y: 200)
    let before = view.canvas(pointer, in: size)
    let zoomed = view.zoomed(by: 1.7, around: pointer, in: size)
    let after = zoomed.canvas(pointer, in: size)
    #expect(zoomed.zoom == 1.5)
    #expect(abs(after.x - before.x) < 1e-9 && abs(after.y - before.y) < 1e-9)
  }

  @Test func zoomStaysInRangeForAnyFactor() {
    let view = Viewport()
    let centre = CGPoint(x: 720, y: 450)
    for factor in [1e9, 1e-9, 0, -3, .infinity, .nan] {
      let result = view.zoomed(by: factor, around: centre, in: size)
      #expect(result.zoom == 0.2 || result.zoom == 1.5 || result.zoom == 1)
      #expect(result.cx.isFinite && result.cy.isFinite)
    }
    #expect(view.zoomed(by: 1e9, around: centre, in: size).zoom == 1.5)
    #expect(view.zoomed(by: 1e-9, around: centre, in: size).zoom == 0.2)
  }

  @Test func revealingPansTheLeastNeeded() {
    let view = Viewport()
    let inside = CGRect(x: -100, y: -100, width: 200, height: 200)
    #expect(view.revealing(inside, in: size, margin: 24) == view)
    let right = CGRect(x: 800, y: -100, width: 200, height: 200)
    let moved = view.revealing(right, in: size, margin: 24)
    #expect(moved.cy == 0)
    #expect(abs(moved.screen(CGPoint(x: 1000, y: 0), in: size).x - (1440 - 24)) < 1e-9)
  }

  @Test func fittingPutsEveryRectInsideTheViewport() {
    let rects = [
      CGRect(x: -2000, y: -300, width: 220, height: 230),
      CGRect(x: 1500, y: 900, width: 220, height: 230),
    ]
    let view = Viewport.fitting(rects, in: size, margin: 96)
    let visible = view.visibleRect(in: size)
    for rect in rects { #expect(visible.contains(rect)) }
    #expect(view.zoom >= 0.2)
  }

  @Test func fittingNothingIsTheOrigin() {
    #expect(Viewport.fitting([], in: size, margin: 96) == Viewport(cx: 0, cy: 0, zoom: 1))
  }

  @Test func fittingCentresTheGroupAndHonoursACapOnTheZoom() {
    let rects = [
      CGRect(x: 0, y: 0, width: 220, height: 230), CGRect(x: 316, y: 0, width: 220, height: 230),
    ]
    let view = Viewport.fitting(rects, in: size, margin: 96, maxZoom: 1)
    #expect(view.zoom == 1)
    #expect(view.cx == 268 && view.cy == 115)
  }

  @Test func fittingASmallGroupNeverZoomsPastTheLimit() {
    let view = Viewport.fitting([CGRect(x: 0, y: 0, width: 10, height: 10)], in: size, margin: 96)
    #expect(view.zoom == 1.5)
  }

  @Test func theZoomPercentIsTheRoundedZoom() {
    #expect(Viewport(zoom: 0.8).zoomPercent == 80)
    #expect(Viewport(zoom: 1).zoomPercent == 100)
    #expect(Viewport(zoom: 1 / 1.25 / 1.25).zoomPercent == 64)
    #expect(Viewport(zoom: 0.2).zoomPercent == 20)
    #expect(Viewport(zoom: 9).zoomPercent == 150)
  }

  @Test func oneWheelStepIsOneZoomStepAndOppositeStepsCancel() {
    #expect(Viewport.wheelFactor(0) == 1)
    #expect(abs(Viewport.wheelFactor(Viewport.wheelStep) - Viewport.zoomStep) < 1e-12)
    #expect(abs(Viewport.wheelFactor(-Viewport.wheelStep) * Viewport.zoomStep - 1) < 1e-12)
  }

  @Test func aWheelFactorIsFiniteAndPositiveForAnyDelta() {
    for delta in [1e12, -1e12, .infinity, -.infinity, .nan] {
      let factor = Viewport.wheelFactor(delta)
      #expect(factor.isFinite && factor > 0)
    }
    #expect(Viewport().zoomed(by: Viewport.wheelFactor(1e12), around: .zero, in: size).zoom == 1.5)
    #expect(Viewport().zoomed(by: Viewport.wheelFactor(-1e12), around: .zero, in: size).zoom == 0.2)
  }
}

@Suite struct CanvasNavigationTests {
  private let grid = [
    node("n1", 0, 0), node("n2", 244, 0), node("n3", 488, 0), node("n4", 0, 254),
    node("n5", 244, 254),
  ]

  @Test func arrowsPickTheNearestNodeInThatDirection() {
    #expect(CanvasNavigation.nearest(from: "n1", toward: .right, in: grid) == "n2")
    #expect(CanvasNavigation.nearest(from: "n2", toward: .right, in: grid) == "n3")
    #expect(CanvasNavigation.nearest(from: "n1", toward: .down, in: grid) == "n4")
    #expect(CanvasNavigation.nearest(from: "n5", toward: .up, in: grid) == "n2")
    #expect(CanvasNavigation.nearest(from: "n5", toward: .left, in: grid) == "n4")
  }

  @Test func noNodeThatWayLeavesTheSelectionAlone() {
    #expect(CanvasNavigation.nearest(from: "n1", toward: .left, in: grid) == nil)
    #expect(CanvasNavigation.nearest(from: "n1", toward: .up, in: grid) == nil)
    #expect(CanvasNavigation.nearest(from: "missing", toward: .right, in: grid) == nil)
  }

  @Test func everyNodeIsReachableFromAnyOtherByArrows() {
    let scattered = [node("n1", 0, 0), node("n2", 100, 400), node("n3", -300, 50)]
    var reached: Set<String> = ["n1"]
    var frontier = ["n1"]
    while let current = frontier.popLast() {
      for direction in [Direction.left, .right, .up, .down] {
        if let next = CanvasNavigation.nearest(from: current, toward: direction, in: scattered),
          reached.insert(next).inserted
        {
          frontier.append(next)
        }
      }
    }
    #expect(reached.count == 3)
  }
}

@Suite struct EdgeRouteTests {
  private let left = CGRect(x: 0, y: 0, width: 220, height: 184)

  @Test func aSideBySidePairJoinsFacingEdgeMidpoints() {
    let right = CGRect(x: 400, y: 0, width: 220, height: 184)
    let route = EdgeRoute.make(from: left, to: right, bow: 12)
    #expect(route.start == CGPoint(x: 220, y: 92))
    #expect(route.end == CGPoint(x: 400, y: 92))
    #expect(abs(abs(route.control.y - 92) - 12) < 1e-9)
    #expect(route.control.x == 310)
  }

  @Test func aStackedPairJoinsTopAndBottom() {
    let below = CGRect(x: 0, y: 400, width: 220, height: 184)
    let route = EdgeRoute.make(from: left, to: below, bow: 12)
    #expect(route.start == CGPoint(x: 110, y: 184))
    #expect(route.end == CGPoint(x: 110, y: 400))
  }

  @Test func sidewaysJoinsSideEdgesEvenWhenTheTargetLiesFarBelow() {
    let page = CGRect(x: 400, y: 0, width: 632, height: 532)
    let low = CGRect(x: 0, y: 1000, width: 220, height: 184)
    let route = EdgeRoute.make(from: low, to: page, bow: 12, sideways: true)
    #expect(route.start.x == 220)
    #expect(route.end.x == 400)
  }

  @Test func theSamePairAlwaysBowsTheSameWay() {
    let right = CGRect(x: 400, y: 0, width: 220, height: 184)
    #expect(
      EdgeRoute.make(from: left, to: right, bow: 12)
        == EdgeRoute.make(from: left, to: right, bow: 12))
  }
}

@Suite struct NodeFrameTests {
  @Test func theCardSitsAtTheTopOfItsSlotGroup() {
    let page = node("n1", 100, 200)
    #expect(page.frame == CGRect(x: -10, y: 85, width: 220, height: 230))
    #expect(page.cardFrame == CGRect(x: -10, y: 85, width: 220, height: 184))
  }
}
