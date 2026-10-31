import CoreGraphics
import Testing

@testable import BarestateCore

@Suite struct LauncherGeometryTests {
  private let desktop = CGSize(width: 1440, height: 900)

  @Test func theEmptyLauncherIsThePhotonPanel() {
    let list = LauncherGeometry.listHeight(sections: 3, rows: 6)
    let panel = LauncherGeometry.panel(window: desktop, listHeight: list).frame
    #expect(panel == CGRect(x: 340, y: 122, width: 760, height: 630))
  }

  @Test func typingKeepsTheTopAndShrinksTheList() {
    let list = LauncherGeometry.listHeight(sections: 2, rows: 4)
    let panel = LauncherGeometry.panel(window: desktop, listHeight: list).frame
    #expect(panel == CGRect(x: 340, y: 122, width: 760, height: 474))
  }

  @Test func narrowWindowsKeepA24PointMargin() {
    let window = CGSize(width: 720, height: 600)
    let panel = LauncherGeometry.panel(
      window: window, listHeight: LauncherGeometry.listHeight(sections: 1, rows: 2)
    ).frame
    #expect(panel.minX == 24)
    #expect(panel.width == 672)
  }

  @Test func aTallListScrollsInsideAndNeverLeavesTheWindow() {
    let window = CGSize(width: 1200, height: 600)
    let list = LauncherGeometry.listHeight(sections: 3, rows: 6)
    let (panel, shown) = LauncherGeometry.panel(window: window, listHeight: list)
    #expect(shown < list)
    #expect(panel.minY >= LauncherGeometry.margin)
    #expect(panel.maxY <= window.height - LauncherGeometry.margin)
  }

  @Test func threePagesStillFitUnderTheFixedTopAtDesktopHeight() {
    let list = LauncherGeometry.listHeight(sections: 3, rows: 8)
    let panel = LauncherGeometry.panel(window: desktop, listHeight: list).frame
    #expect(panel.minY == 122)
    #expect(panel.maxY <= desktop.height)
  }

  @Test func aPanelThatDoesNotFitMovesUpInsteadOfOverflowing() {
    let window = CGSize(width: 1440, height: 600)
    let (panel, shown) = LauncherGeometry.panel(
      window: window, listHeight: LauncherGeometry.listHeight(sections: 3, rows: 6))
    #expect(panel.minY < 122)
    #expect(panel.minY >= LauncherGeometry.margin)
    #expect(panel.maxY <= window.height)
    #expect(shown < LauncherGeometry.listHeight(sections: 3, rows: 6))
  }

  @Test func aShortPanelSitsAtTheFixedTopInATallWindow() {
    let (panel, _) = LauncherGeometry.panel(window: desktop, listHeight: 0)
    #expect(panel.minY == 122)
    #expect(panel.height == 162)
  }

  @Test func tenOpenPagesStayInTheFigmaPanelAndScroll() {
    let list = LauncherGeometry.listHeight(sections: 3, rows: 10)
    let (panel, shown) = LauncherGeometry.panel(window: desktop, listHeight: list)
    #expect(panel == CGRect(x: 340, y: 122, width: 760, height: 630))
    #expect(shown == 468)
    #expect(shown < list)
  }

  @Test func theShortestWindowKeepsMarginsAndClearsTheChip() {
    let window = CGSize(width: 720, height: 600)
    let (panel, shown) = LauncherGeometry.panel(
      window: window, listHeight: LauncherGeometry.listHeight(sections: 3, rows: 10))
    #expect(panel.minY >= LauncherGeometry.margin)
    #expect(panel.maxY <= window.height - 60 - 12)
    #expect(panel.minX == 24 && panel.width == 672)
    #expect(shown >= LauncherGeometry.rowHeight)
  }

  @Test(arguments: [1.5, 2.0])
  func largerTextGrowsRowsAndStillFitsTheShortestWindow(scale: Double) {
    let window = CGSize(width: 720, height: 600)
    let list = LauncherGeometry.listHeight(sections: 2, rows: 4, scale: scale)
    #expect(list == LauncherGeometry.listHeight(sections: 2, rows: 4) * scale)
    let (panel, shown) = LauncherGeometry.panel(window: window, listHeight: list, scale: scale)
    #expect(panel.minY >= LauncherGeometry.margin)
    #expect(panel.maxY <= window.height - 40 * scale - 20 - 12)
    #expect(shown >= LauncherGeometry.rowHeight * scale)
    #expect(panel.minX == 24)
  }
}
