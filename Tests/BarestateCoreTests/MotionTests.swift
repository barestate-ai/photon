import CoreGraphics
import Testing

@testable import BarestateCore

@Suite struct MotionTests {
  @Test func everySpringIsCalmEnoughForUI() {
    for spring in [SpringSpec.camera, .rubberBack, .drop] {
      #expect(spring.bounce <= 0.2, "mass \(spring.mass) stiffness \(spring.stiffness)")
    }
    #expect(SpringSpec.camera.bounce == 0)
  }

  @Test func settlingTimeFitsTheCameraCap() {
    #expect(SpringSpec.camera.settlingEstimate <= 0.45)
    #expect(SpringSpec.rubberBack.settlingEstimate <= 0.45)
  }

  @Test func rubberBandLeavesTheRangeAlone() {
    let range = Viewport.zoomRange
    #expect(RubberBand.shown(1.0, in: range) == 1.0)
    #expect(RubberBand.shown(range.upperBound, in: range) == range.upperBound)
    #expect(RubberBand.shown(range.lowerBound, in: range) == range.lowerBound)
  }

  @Test func rubberBandOvershootIsBoundedAndMonotonic() {
    let range = Viewport.zoomRange
    var last = range.upperBound
    for raw in stride(from: 1.55, through: 3.0, by: 0.25) {
      let shown = RubberBand.shown(raw, in: range)
      #expect(shown > last)
      #expect(shown <= range.upperBound * 1.12)
      last = shown
    }
    var low = range.lowerBound
    for raw in stride(from: 0.19, through: 0.0, by: -0.03) {
      let shown = RubberBand.shown(raw, in: range)
      #expect(shown < low)
      #expect(shown >= range.lowerBound * 0.88)
      low = shown
    }
  }

  @Test func rectMotionMapsOneCardOntoAnother() {
    let page = CGRect(x: 100, y: 80, width: 800, height: 500)
    let card = CGRect(x: 40, y: 300, width: 220, height: 184)
    let move = RectMotion(from: page, to: card)
    #expect(abs(move.scaleX - 220.0 / 800) < 1e-9)
    #expect(abs(move.scaleY - 184.0 / 500) < 1e-9)
    // About the centre: the centres line up once the translation is applied.
    #expect(abs(move.translateX - (card.midX - page.midX)) < 1e-9)
    #expect(abs(move.translateY - (card.midY - page.midY)) < 1e-9)
    let same = RectMotion(from: page, to: page)
    #expect(same.isIdentity)
  }
}
