import Foundation

/// The socket client a request came from, so a method such as `events.subscribe` can keep
/// writing to it after it has replied.
@MainActor
public final class RPCPeer {
  /// Sends one line (no newline). A frame may be dropped for a newer one; anything else that
  /// cannot be queued disconnects the client.
  public let send: (Data, _ frame: Bool) -> Void
  public let disconnect: () -> Void
  private var closeHandlers: [() -> Void] = []

  public init(send: @escaping (Data, Bool) -> Void, disconnect: @escaping () -> Void) {
    self.send = send
    self.disconnect = disconnect
  }

  public func onClose(_ handler: @escaping () -> Void) { closeHandlers.append(handler) }

  /// Called by the transport once, when the client is gone.
  public func closed() {
    let handlers = closeHandlers
    closeHandlers = []
    for handler in handlers { handler() }
  }
}

public enum RPCContext {
  /// The client whose request the current handler is answering; nil for a call from inside the app.
  @TaskLocal public static var peer: RPCPeer?
}
