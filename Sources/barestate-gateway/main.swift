import BarestateCore
import Foundation
import Network

// The remote door to Photon: HTTP on loopback (Tailscale Funnel forwards to it), MCP requests
// relayed to the app's socket. See architecture §8.

@MainActor
func serve(_ options: Options) {
  let gateway = Gateway(options: options)
  let parameters = NWParameters.tcp
  parameters.requiredLocalEndpoint = .hostPort(
    host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: options.port)!)
  parameters.allowLocalEndpointReuse = true
  let listener: NWListener
  do {
    listener = try NWListener(using: parameters)
  } catch {
    warn("cannot listen on 127.0.0.1:\(options.port): \(error)")
    exit(1)
  }
  listener.newConnectionHandler = { connection in
    MainActor.assumeIsolated { gateway.accept(connection) }
  }
  listener.stateUpdateHandler = { state in
    MainActor.assumeIsolated {
      switch state {
      case .ready: gateway.note("listening port=\(options.port)")
      case .failed(let error):
        warn("listener failed: \(error)")
        exit(1)
      default: break
      }
    }
  }
  listener.start(queue: .main)
}

signal(SIGPIPE, SIG_IGN)
let options = Options(CommandLine.arguments)
let parentExit = options.parent.map {
  let source = DispatchSource.makeProcessSource(identifier: $0, eventMask: .exit, queue: .main)
  source.setEventHandler {
    if options.unmountFunnelOnExit { _ = Remote.runTailscale(Remote.funnelUnmount) }
    exit(0)
  }
  source.resume()
  return source
}
Task { @MainActor in serve(options) }
// dispatchMain() would run the main queue off the main thread, which assumeIsolated rejects.
RunLoop.main.run()
