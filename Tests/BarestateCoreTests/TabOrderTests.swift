import BarestateCore
import Testing

struct TabOrderTests {
  private func make(_ ids: [String], active: String? = nil) -> TabOrder {
    var order = TabOrder()
    for id in ids { order.append(id, activate: false) }
    if let active { order.activate(active) }
    return order
  }

  @Test func recencyListsTheLastUsedTabFirstAndUnshownTabsAfterInTabOrder() {
    var order = make(["a", "b", "c", "d"])
    #expect(order.recency == ["a", "b", "c", "d"])
    order.activate("c")
    order.activate("b")
    #expect(order.recency == ["b", "c", "a", "d"])
    order.activate("c")
    #expect(order.recency.first == "c")
    order.append("e", activate: true)
    #expect(order.recency == ["e", "c", "b", "a", "d"])
  }

  @Test func aClosedTabLeavesTheRecencyAndItsReplacementCountsAsUsed() {
    var order = make(["a", "b", "c"])
    order.activate("b")
    order.activate("c")
    order.remove("c")
    #expect(order.active == "b")
    #expect(order.recency == ["b", "a"])
    order.remove("a")
    #expect(order.recency == ["b"])
  }

  @Test func theFirstTabBecomesActiveAndLaterOnesOnlyWhenAsked() {
    var order = TabOrder()
    order.append("a", activate: false)
    order.append("b", activate: false)
    #expect(order.active == "a")
    order.append("c", activate: true)
    #expect(order.active == "c")
    #expect(order.ids == ["a", "b", "c"])
  }

  @Test func closingTheActiveTabSelectsItsRightNeighbourElseTheLast() {
    var order = make(["a", "b", "c"], active: "b")
    #expect(order.remove("b") == 1)
    #expect(order.active == "c")
    #expect(order.remove("c") == 1)
    #expect(order.active == "a")
    #expect(order.remove("a") == 0)
    #expect(order.active == nil)
    #expect(order.ids.isEmpty)
  }

  @Test func closingAnotherTabKeepsTheActiveOne() {
    var order = make(["a", "b", "c"], active: "c")
    _ = order.remove("a")
    #expect(order.active == "c")
    #expect(order.remove("zzz") == nil)
  }

  @Test func cyclingWrapsInBothDirections() {
    #expect(make(["a", "b", "c"], active: "c").cycled(by: 1) == "a")
    #expect(make(["a", "b", "c"], active: "a").cycled(by: -1) == "c")
    #expect(make(["a", "b", "c"], active: "a").cycled(by: 1) == "b")
    #expect(TabOrder().cycled(by: 1) == nil)
  }

  @Test func numberShortcutsPickTabsOneToEightAndNineIsTheLast() {
    let ids = (1...10).map { "t\($0)" }
    let order = make(ids)
    #expect(order.shortcutTarget(1) == "t1")
    #expect(order.shortcutTarget(8) == "t8")
    #expect(order.shortcutTarget(9) == "t10")
    #expect(make(["a", "b"]).shortcutTarget(5) == nil)
    #expect(make(["a", "b"]).shortcutTarget(9) == "b")
    #expect(TabOrder().shortcutTarget(9) == nil)
  }

  @Test func movingReordersAndClampsTheIndex() {
    var order = make(["a", "b", "c", "d"], active: "a")
    order.move("a", to: 2)
    #expect(order.ids == ["b", "c", "a", "d"])
    order.move("d", to: -4)
    #expect(order.ids == ["d", "b", "c", "a"])
    order.move("d", to: 99)
    #expect(order.ids == ["b", "c", "a", "d"])
    #expect(order.active == "a")
  }

  @Test func insertingPutsATabBackAtItsIndex() {
    var order = make(["a", "c"], active: "a")
    order.insert("b", at: 1, activate: true)
    #expect(order.ids == ["a", "b", "c"])
    #expect(order.active == "b")
    order.insert("z", at: 50, activate: false)
    #expect(order.ids.last == "z")
  }

  @Test func closedTabsComeBackNewestFirstAndAreCapped() {
    var closed = ClosedTabs(limit: 3)
    for n in 1...4 { closed.push(ClosedTabs.Entry(url: "u\(n)", title: "T\(n)", index: n)) }
    #expect(closed.pop()?.url == "u4")
    #expect(closed.pop()?.url == "u3")
    #expect(closed.pop()?.url == "u2")
    #expect(closed.pop() == nil)
  }
}
