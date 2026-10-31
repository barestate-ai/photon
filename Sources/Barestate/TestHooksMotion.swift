import AppKit
import BarestateCore

@MainActor
extension AppController {
  /// `test.ui.motion`: every animation in flight and the last 64 finished, the camera's flight
  /// layer and the live view's frame. Rects are window points from the top left.
  func motionState() -> JSON {
    guard case .object(var fields) = MotionLedger.shared.state() else { return .null }
    let live = activeTab?.view
    let moving = camera.isMoving
    let button = root?.commandButton.layer
    fields["camera"] = [
      "presentation": .string(presentation.rawValue),
      "phase": .string(moving ? "moving" : (camera.layerKind != nil ? "landing" : "idle")),
      "layer": camera.layerKind.map { .string($0) } ?? .null,
      "generation": .number(Double(camera.generation)),
      "rect": camera.flightRect.map { json($0) } ?? .null,
      "liveFrame": live.map(windowRect) ?? .null,
      "liveVisible": .bool(live.map { !$0.isHidden && container?.isHidden == false } ?? false),
      "commandButtonScale": .number(Double((button?.presentation() ?? button)?.transform.m11 ?? 1)),
      "stretchScale": .number(root?.canvasView?.stretchScale ?? 1),
      "canvasOpacity": .number(
        Double((root?.canvasView?.layer?.presentation() ?? root?.canvasView?.layer)?.opacity ?? 0)),
    ]
    return .object(fields)
  }
}

/// `test.motion` reads the motion state alone, cheap enough to sample every 16 ms. `settle: true`
/// ends every running animation at its final frame first.
@MainActor
func registerMotionHooks(_ dispatcher: RPCDispatcher, controller: AppController) {
  dispatcher.register("test.motion") { params in
    if params["settle"]?.bool == true { MotionLedger.shared.settleAll() }
    return controller.motionState()
  }

  // The only notice the app shows appears with a camera move; this one can come on an idle canvas.
  dispatcher.register("test.notice") { params in
    controller.notify(try params.requireString("text"))
    return [:]
  }
}
