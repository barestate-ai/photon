import AppKit

@MainActor
final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
