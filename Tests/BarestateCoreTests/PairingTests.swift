import BarestateCore
import Foundation
import Testing

struct PairingTests {
  private func scratch() -> String {
    let dir = NSTemporaryDirectory() + "bs-pairing-\(UUID().uuidString.prefix(8))"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func aMintedTokenIs32RandomBytesAndOnlyItsHashIsStored() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = PairingStore(path: dir + "/pairing.json")
    let token = try store.mint(label: "Phone")
    #expect(token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    let file = try String(contentsOfFile: store.path, encoding: .utf8)
    #expect(!file.contains(token))
    let stored = try #require(store.list().first)
    #expect(stored.hash == PairingStore.hash(token))
    #expect(stored.hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    #expect(stored.label == "Phone")
    #expect(!stored.created.isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)
    #expect(try store.mint(label: "Phone") != token)
  }

  @Test func theHashIsTheSHA256OfTheTokenText() {
    // printf %s abc | shasum -a 256
    #expect(
      PairingStore.hash("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func onlyAStoredTokenAuthenticatesAndRevokingEndsIt() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = PairingStore(path: dir + "/pairing.json")
    #expect(store.authenticate("nothing") == nil)
    let first = try store.mint(label: "A")
    let second = try store.mint(label: "B")
    #expect(store.authenticate(first)?.label == "A")
    #expect(store.authenticate(second)?.label == "B")
    #expect(store.authenticate(first + "0") == nil)
    #expect(store.authenticate("") == nil)
    try store.revoke(hash: PairingStore.hash(first))
    #expect(store.authenticate(first) == nil)
    #expect(store.authenticate(second)?.label == "B")
    #expect(store.list().count == 1)
  }

  @Test func aMissingOrBrokenFileHasNoPairings() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = PairingStore(path: dir + "/pairing.json")
    #expect(store.list().isEmpty)
    try "not json".write(toFile: store.path, atomically: true, encoding: .utf8)
    #expect(store.list().isEmpty)
    #expect(store.authenticate("x") == nil)
  }

  @Test func lastSeenIsKeptApartFromThePairingsAndLeavesWhenTheyDo() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = PairingStore(path: dir + "/pairing.json")
    let first = PairingStore.hash(try store.mint(label: "A"))
    let second = PairingStore.hash(try store.mint(label: "B"))
    #expect(store.lastSeen().isEmpty)
    let before = try String(contentsOfFile: store.path, encoding: .utf8)
    store.markSeen(hash: first, now: Date(timeIntervalSince1970: 0))
    store.markSeen(hash: second, now: Date(timeIntervalSince1970: 60))
    #expect(try String(contentsOfFile: store.path, encoding: .utf8) == before)
    #expect(store.lastSeen()[first] == "1970-01-01T00:00:00Z")
    #expect(store.lastSeen()[second] == "1970-01-01T00:01:00Z")
    try store.revoke(hash: first)
    store.markSeen(hash: second, now: Date(timeIntervalSince1970: 120))
    #expect(Set(store.lastSeen().keys) == [second])
  }

  @Test func aStrangerIsNeverRecordedAsSeen() {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = PairingStore(path: dir + "/pairing.json")
    store.markSeen(hash: PairingStore.hash("nobody"))
    #expect(store.lastSeen().isEmpty)
  }
}
