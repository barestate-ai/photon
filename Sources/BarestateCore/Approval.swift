import CryptoKit
import Foundation

/// What an Allow once is good for (architecture §5.6): one action, on one document, in one epoch.
/// The token is minted when the action is quoted and recomputed from the tab's current state
/// before dispatch, so anything that moved since the human looked cancels it.
public struct ApprovalBinding: Equatable, Sendable {
  public let tabId: String
  public let epoch: UInt64
  public let documentKey: String
  public let ref: Int
  public let kind: ActionKind
  public let textHash: String?

  public init(
    tabId: String, epoch: UInt64, documentKey: String, ref: Int, kind: ActionKind,
    textHash: String?
  ) {
    self.tabId = tabId
    self.epoch = epoch
    self.documentKey = documentKey
    self.ref = ref
    self.kind = kind
    self.textHash = textHash
  }

  public var token: String {
    let fields = "\(tabId)|\(epoch)|\(documentKey)|\(ref)|\(kind.rawValue)|\(textHash ?? "")"
    return SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Why `now` no longer honours this binding, or nil when the tokens match.
  public func staleReason(against now: ApprovalBinding) -> StaleReason? {
    if epoch != now.epoch { return .epoch }
    if documentKey != now.documentKey { return .documentKey }
    return token == now.token ? nil : .target
  }
}
