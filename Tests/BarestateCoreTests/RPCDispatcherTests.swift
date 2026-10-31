import BarestateCore
import Foundation
import Testing

@MainActor
struct RPCDispatcherTests {
  private func call(_ dispatcher: RPCDispatcher, _ line: String) async -> JSON? {
    guard let data = await dispatcher.handle(line: Data(line.utf8)) else { return nil }
    return try? JSONDecoder().decode(JSON.self, from: data)
  }

  private func makeDispatcher(testHooks: Bool) -> RPCDispatcher {
    let dispatcher = RPCDispatcher(testHooks: testHooks)
    dispatcher.register("app.status") { _ in .object(["ready": .bool(true)]) }
    dispatcher.register("test.ui") { _ in .string("ui") }
    return dispatcher
  }

  @Test func returnsResultForRegisteredMethod() async {
    let reply = await call(
      makeDispatcher(testHooks: false), #"{"jsonrpc":"2.0","id":7,"method":"app.status"}"#)
    #expect(reply?["id"] == .number(7))
    #expect(reply?["result"]?["ready"] == .bool(true))
    #expect(reply?["jsonrpc"] == .string("2.0"))
  }

  @Test func echoesStringIds() async {
    let reply = await call(
      makeDispatcher(testHooks: false), #"{"jsonrpc":"2.0","id":"a-1","method":"app.status"}"#)
    #expect(reply?["id"] == .string("a-1"))
  }

  @Test func unknownMethodIsMethodNotFound() async {
    let reply = await call(
      makeDispatcher(testHooks: false), #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)
    #expect(reply?["error"]?["code"] == .number(-32601))
  }

  @Test func testMethodsAreMethodNotFoundWithoutTheFlag() async {
    let reply = await call(
      makeDispatcher(testHooks: false), #"{"jsonrpc":"2.0","id":1,"method":"test.ui"}"#)
    #expect(reply?["error"]?["code"] == .number(-32601))
    #expect(reply?["result"] == nil)
  }

  @Test func anInProcessCallReachesTheSameHandlersAndTheSameGate() async throws {
    let dispatcher = makeDispatcher(testHooks: false)
    #expect(try await dispatcher.call("app.status", .null)["ready"] == .bool(true))
    await #expect(throws: RPCError.methodNotFound) { try await dispatcher.call("test.ui", .null) }
    await #expect(throws: RPCError.methodNotFound) { try await dispatcher.call("nope", .null) }
  }

  @Test func testMethodsWorkWithTheFlag() async {
    let reply = await call(
      makeDispatcher(testHooks: true), #"{"jsonrpc":"2.0","id":1,"method":"test.ui"}"#)
    #expect(reply?["result"] == .string("ui"))
  }

  @Test func malformedJSONIsParseErrorWithNullId() async {
    let reply = await call(makeDispatcher(testHooks: false), "{not json")
    #expect(reply?["error"]?["code"] == .number(-32700))
    #expect(reply?["id"] == .null)
  }

  @Test func wrongVersionOrMissingMethodIsInvalidRequest() async {
    let dispatcher = makeDispatcher(testHooks: false)
    let wrongVersion = await call(dispatcher, #"{"jsonrpc":"1.0","id":1,"method":"app.status"}"#)
    #expect(wrongVersion?["error"]?["code"] == .number(-32600))
    let noMethod = await call(dispatcher, #"{"jsonrpc":"2.0","id":1}"#)
    #expect(noMethod?["error"]?["code"] == .number(-32600))
    let batch = await call(dispatcher, #"[{"jsonrpc":"2.0","id":1,"method":"app.status"}]"#)
    #expect(batch?["error"]?["code"] == .number(-32600))
  }

  @Test func notificationsGetNoReply() async {
    let reply = await call(
      makeDispatcher(testHooks: false), #"{"jsonrpc":"2.0","method":"app.status"}"#)
    #expect(reply == nil)
  }

  @Test func handlerErrorsBecomeErrorReplies() async {
    let dispatcher = makeDispatcher(testHooks: false)
    dispatcher.register("bad") { _ in throw RPCError.invalidParams("need x") }
    dispatcher.register("boom") { _ in throw CocoaError(.fileNoSuchFile) }
    let invalid = await call(dispatcher, #"{"jsonrpc":"2.0","id":1,"method":"bad"}"#)
    #expect(invalid?["error"]?["code"] == .number(-32602))
    #expect(invalid?["error"]?["message"] == .string("need x"))
    let internalError = await call(dispatcher, #"{"jsonrpc":"2.0","id":2,"method":"boom"}"#)
    #expect(internalError?["error"]?["code"] == .number(-32603))
  }

  @Test func handlersReceiveParams() async {
    let dispatcher = makeDispatcher(testHooks: false)
    dispatcher.register("echo") { params in params }
    let reply = await call(
      dispatcher, #"{"jsonrpc":"2.0","id":1,"method":"echo","params":{"a":[1,"b",null]}}"#)
    #expect(reply?["result"]?["a"] == .array([.number(1), .string("b"), .null]))
  }
}
