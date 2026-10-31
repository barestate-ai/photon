import Foundation

/// Posted events are matched on the way out by their timestamp. AppKit hands them back with the
/// timestamp cut to nanoseconds when the app is not truly active (a locked screen), so exact
/// Double equality never matches. Stamps sit on a whole-microsecond grid and compare as integers.
public enum EventStamp {
  public static func tick(_ time: TimeInterval) -> Int64 { Int64((time * 1e6).rounded()) }

  public static func time(ofTick tick: Int64) -> TimeInterval { TimeInterval(tick) / 1e6 }
}
