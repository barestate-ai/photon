import Foundation
import Network

/// Whether the system has a usable network path. It starts satisfied, so a launch is not
/// blocked before the monitor's first report.
final class NetworkPath: @unchecked Sendable {
  private let lock = NSLock()
  private var up = true
  private let monitor = NWPathMonitor()

  var satisfied: Bool {
    get { lock.withLock { up } }
    set { lock.withLock { up = newValue } }
  }

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in self?.satisfied = path.status == .satisfied }
    monitor.start(queue: DispatchQueue(label: "ai.barestate.photon.network-path"))
  }
}
