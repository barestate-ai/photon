import BarestateCore
import Foundation
import Testing

struct EventStampTests {
  @Test func aTimestampCutToNanosecondsKeepsItsTick() {
    for tick: Int64 in [40_491_880_629_583, 40_491_880_629_584, 1, 999_999_999_999] {
      let stamp = EventStamp.time(ofTick: tick)
      let cut = (stamp * 1e9).rounded(.down) / 1e9
      #expect(EventStamp.tick(cut) == tick)
      #expect(EventStamp.tick(stamp) == tick)
    }
  }

  @Test func neighbouringTicksStayDistinct() {
    let stamp = EventStamp.time(ofTick: 40_491_880_629_583)
    #expect(EventStamp.tick(stamp + 1e-6) == 40_491_880_629_584)
  }
}
