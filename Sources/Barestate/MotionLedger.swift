import AppKit
import BarestateCore

/// The one place an animation starts. Every Core Animation the app runs goes through `start`, so
/// `test.ui` can say what is in flight, why, and on which curve, and an interrupted move is
/// recorded as one.
@MainActor
final class MotionLedger: NSObject, CAAnimationDelegate {
  static let shared = MotionLedger()

  /// What each kind is for. The names are the contract's (VAL-MOTION-004).
  enum Kind: String {
    case camera, rubberBack
    case nodeEnter, firstRun
    case trailDraw
    case previewCrossfade, previewStale
    case buttonPress, buttonHover, nodePress, nodePickup, nodeDrop
    case rowState, museLabel
    case approvalIn, approvalOut, activityIn, activityOut, stepIn
    case notice, statusDot, buttonFade, atomState, museState
    case qrReveal, phoneChip
    case musePulse, completion, trailFlow, thinkingOrb

    var purpose: String {
      switch self {
      case .camera, .rubberBack: "camera"
      case .nodeEnter, .firstRun: "node-entrance"
      case .trailDraw: "trail-draw"
      case .previewCrossfade, .previewStale: "preview-crossfade"
      case .buttonPress, .buttonHover, .nodePress, .nodePickup, .nodeDrop: "button-press"
      case .rowState, .museLabel: "result-state"
      case .musePulse: "muse-pulse"
      case .completion: "completion"
      case .approvalIn, .approvalOut, .activityIn: "approval-entrance"
      case .activityOut, .stepIn: "panel-fade"
      case .notice: "notice-fade"
      case .statusDot, .buttonFade, .atomState, .museState: "status-fade"
      case .trailFlow: "trail-flow"
      case .thinkingOrb: "thinking-orb"
      case .qrReveal: "pairing-reveal"
      case .phoneChip: "status-chip"
      }
    }
  }

  struct Part {
    let layer: CALayer
    let key: String
    let animation: CAAnimation
  }

  struct Item {
    let id: Int
    let kind: Kind
    let target: String
    let generation: Int
    let keyPaths: [String]
    let curve: String
    let bounce: Double
    let startedAtMs: Double
    let durationMs: Double
    let delayMs: Double
    let reduced: Bool
    let transformChanged: Bool
    let from: JSON
    let to: JSON
    var interrupted = false
  }

  /// Wired by the app: the system setting or the test override.
  var reduced: () -> Bool = { false }

  /// Called when the last animation in flight ends.
  var onIdle: (() -> Void)?

  private(set) var inFlight: [Item] = []
  private(set) var recent: [Item] = []
  private var nextId = 1
  private var pending: [Int: Pending] = [:]
  /// Counters the contract reads (VAL-MOTION-002).
  private(set) var cefResizesDuringMove = 0
  private(set) var previewCaptureTimeouts = 0

  private final class Pending {
    var parts: [Part]
    var remaining: Int
    var finished = true
    let then: ((Bool) -> Void)?
    init(parts: [Part], then: ((Bool) -> Void)?) {
      self.parts = parts
      remaining = parts.count
      self.then = then
    }
  }

  /// Ambient animations that run until something stops them. They are listed apart from
  /// `inFlight`, which only ever holds what ends by itself.
  private struct Loop {
    let kind: Kind
    let target: String
    let runId: String
    let surface: String
    let layer: CALayer
    let key: String
    /// What the animation added to the layer is, read from it where it was built.
    let keyPath: String
    let curve: String
    /// One pass of the loop, in seconds.
    let durationS: Double
  }
  private var loops: [String: Loop] = [:]

  /// Starts `animation` on `layer` until `stopLoop`. The same id for the same run is already
  /// running, so a redraw does not restart it.
  func startLoop(
    _ kind: Kind, id: String, target: String, runId: String, surface: String, layer: CALayer,
    key: String, animation: CAAnimation
  ) {
    if loops[id]?.runId == runId { return }
    stopLoop(id, settle: false)
    loops[id] = Loop(
      kind: kind, target: target, runId: runId, surface: surface, layer: layer, key: key,
      keyPath: (animation as? CAPropertyAnimation)?.keyPath ?? "",
      curve: Self.describe(animation).0,
      durationS: animation.duration
    )
    layer.add(animation, forKey: key)
  }

  /// Takes the loop out of the registry now and eases the layer back to rest.
  func stopLoop(_ id: String, settle: Bool = true) {
    guard let loop = loops.removeValue(forKey: id) else { return }
    let from = (Motion.current(loop.layer, "opacity") as? NSNumber)?.floatValue ?? 1
    loop.layer.removeAnimation(forKey: loop.key)
    guard settle else { return }
    start(
      loop.kind, target: loop.target,
      [
        .init(
          layer: loop.layer, key: "\(loop.key).settle",
          animation: Motion.ease("opacity", from: from, to: 1, duration: Motion.fadeSmall))
      ])
  }

  func noteLiveViewResize() { cefResizesDuringMove += 1 }
  func noteCaptureTimeout() { previewCaptureTimeouts += 1 }

  func running(_ kind: Kind) -> Bool { inFlight.contains { $0.kind == kind } }

  /// Adds the animations under their keys, in one transaction with implicit actions off (the
  /// caller has already set the model values). `then` gets whether every part ran to its end; an
  /// interrupted move calls it with false.
  @discardableResult
  func start(
    _ kind: Kind, target: String = "", generation: Int = 0, _ parts: [Part],
    then: ((Bool) -> Void)? = nil
  ) -> Int {
    for part in parts {
      let key = ObjectIdentifier(part.layer)
      for item in inFlight {
        if pending[item.id]?.parts.contains(where: {
          ObjectIdentifier($0.layer) == key && $0.key == part.key
        })
          == true
        {
          finish(item.id, finished: false)
        }
      }
    }
    let id = nextId
    nextId += 1
    let keyPaths = parts.map { ($0.animation as? CAPropertyAnimation)?.keyPath ?? "transition" }
    let longest = parts.map { $0.animation.duration }.max() ?? 0
    let delay = parts.map { Self.delay(of: $0.animation) }.max() ?? 0
    let (curve, bounce) = Self.describe(parts.first?.animation)
    let item = Item(
      id: id, kind: kind, target: target, generation: generation, keyPaths: keyPaths, curve: curve,
      bounce: bounce, startedAtMs: Date().timeIntervalSince1970 * 1000,
      durationMs: (longest * 1000).rounded(), delayMs: (delay * 1000).rounded(),
      reduced: reduced(),
      transformChanged: keyPaths.contains { $0.hasPrefix("transform") || $0 == "position" },
      from: Self.value((parts.first?.animation as? CAPropertyAnimation).flatMap(Self.fromValue)),
      to: Self.value((parts.first?.animation as? CAPropertyAnimation).flatMap(Self.toValue)))
    inFlight.append(item)
    pending[id] = Pending(parts: parts, then: then)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for part in parts {
      part.animation.delegate = self
      part.animation.setValue(id, forKey: "ledgerId")
      part.layer.add(part.animation, forKey: part.key)
    }
    CATransaction.commit()
    // A window nobody can see may never report an animation done, and a move that never lands
    // would leave the page hidden.
    let limit = Duration.seconds(longest + delay + 0.15)
    Task { [weak self] in
      try? await Task.sleep(for: limit)
      self?.finish(id, finished: true, removing: true)
    }
    return id
  }

  nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
    let ledgerId = animation.value(forKey: "ledgerId") as? Int
    MainActor.assumeIsolated {
      guard let id = ledgerId, let item = pending[id] else { return }
      item.finished = item.finished && finished
      item.remaining -= 1
      if item.remaining <= 0 { finish(id, finished: item.finished) }
    }
  }

  private func finish(_ id: Int, finished: Bool, removing: Bool = false) {
    guard let pending = pending.removeValue(forKey: id),
      let index = inFlight.firstIndex(where: { $0.id == id })
    else { return }
    var item = inFlight.remove(at: index)
    item.interrupted = !finished
    recent.append(item)
    if recent.count > 64 { recent.removeFirst() }
    if !finished || removing {
      for part in pending.parts { part.layer.removeAnimation(forKey: part.key) }
    }
    pending.then?(finished)
    if inFlight.isEmpty { onIdle?() }
  }

  /// Drops what `kind` is still doing (for one `target` if given): a new move starts from a clean
  /// layer.
  func cancel(_ kind: Kind, target: String? = nil) {
    for item in inFlight where item.kind == kind && (target == nil || item.target == target) {
      finish(item.id, finished: false)
    }
  }

  /// Ends everything at once: the model values are already final, so this is the settled frame.
  /// A move's landing starts its own fades, so it repeats until nothing is left.
  func settleAll() {
    for _ in 0..<4 where !inFlight.isEmpty {
      for item in inFlight { finish(item.id, finished: true, removing: true) }
    }
  }

  // MARK: Describing an animation

  private static func delay(of animation: CAAnimation) -> Double {
    animation.beginTime > 0 ? max(0, animation.beginTime - CACurrentMediaTime()) : 0
  }

  /// The curve as the registry names it; anything but the strong ease-out, a spring or the trail
  /// flow's linear shows up as `other`, which the contract fails.
  private static func describe(_ animation: CAAnimation?) -> (String, Double) {
    if let spring = animation as? CASpringAnimation {
      let ratio = spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot())
      return ("spring", max(0, 1 - ratio))
    }
    let function = animation?.timingFunction
    if function === Motion.linear { return ("linear", 0) }
    return (function === Motion.easeOut ? "easeOut" : "other", 0)
  }

  // MARK: Test state

  private static func fromValue(_ animation: CAPropertyAnimation) -> Any? {
    (animation as? CABasicAnimation)?.fromValue
  }

  private static func toValue(_ animation: CAPropertyAnimation) -> Any? {
    (animation as? CABasicAnimation)?.toValue
  }

  /// A scale and a translation for a transform, the number itself otherwise.
  private static func value(_ any: Any?) -> JSON {
    if let value = any as? NSValue, String(cString: value.objCType).hasPrefix("{CATransform3D") {
      let t = value.caTransform3DValue
      return ["scale": .number(t.m11), "x": .number(t.m41), "y": .number(t.m42)]
    }
    if let number = any as? NSNumber { return .number(number.doubleValue) }
    return .null
  }

  private func json(_ item: Item) -> JSON {
    [
      "id": .number(Double(item.id)), "kind": .string(item.kind.rawValue),
      "purpose": .string(item.kind.purpose), "target": .string(item.target),
      "keyPaths": .array(item.keyPaths.map { .string($0) }),
      "curve": .string(item.curve), "bounce": .number(item.bounce),
      "startedAtMs": .number(item.startedAtMs), "durationMs": .number(item.durationMs),
      "delayMs": .number(item.delayMs), "generation": .number(Double(item.generation)),
      "reduced": .bool(item.reduced), "transformChanged": .bool(item.transformChanged),
      "from": item.from, "to": item.to,
      "interrupted": .bool(item.interrupted),
    ]
  }

  func state() -> JSON {
    [
      "reduceMotion": .bool(reduced()),
      "inFlight": .array(inFlight.map(json)), "recent": .array(recent.map(json)),
      "counters": [
        "cefResizesDuringCamera": .number(Double(cefResizesDuringMove)),
        "previewCaptureTimeouts": .number(Double(previewCaptureTimeouts)),
      ],
      "infiniteLoops": .array(
        loops.values.sorted { $0.surface + $0.target < $1.surface + $1.target }.map {
          [
            "kind": .string($0.kind.rawValue), "purpose": .string($0.kind.purpose),
            "target": .string($0.target), "runId": .string($0.runId),
            "surface": .string($0.surface), "keyPaths": .array([.string($0.keyPath)]),
            "curve": .string($0.curve), "durationS": .number($0.durationS),
          ]
        }),
    ]
  }
}
