import BarestateCore
import Foundation
import Testing

struct JSONTests {
  @Test func parsesNestedValuesAndKeepsBooleansApartFromNumbers() {
    let json = JSON.parse(Data(#"{"a":[1,true,null,"x",2.5],"b":{"c":false,"d":0}}"#.utf8))
    #expect(
      json
        == .object([
          "a": .array([.number(1), .bool(true), .null, .string("x"), .number(2.5)]),
          "b": .object(["c": .bool(false), "d": .number(0)]),
        ]))
  }

  @Test func emptyInputIsAnEmptyObject() {
    #expect(JSON.parse(Data()) == .object([:]))
  }

  @Test func malformedInputIsNil() {
    #expect(JSON.parse(Data("{nope".utf8)) == nil)
  }

  @Test func serializesWithEscapesAndRoundTrips() throws {
    let value: JSON = ["text": "a \"quoted\"\nline / slash", "n": 3, "list": [true, nil]]
    let text = value.serialized()
    #expect(!text.contains("\\/"))
    #expect(JSON.parse(Data(text.utf8)) == value)
  }

  @Test func accessorsReturnTypedValuesOrNil() {
    let json: JSON = ["s": "x", "n": 4, "b": true, "a": [1], "o": ["k": 1]]
    #expect(json["s"]?.string == "x")
    #expect(json["n"]?.int == 4)
    #expect(json["b"]?.bool == true)
    #expect(json["a"]?.array?.count == 1)
    #expect(json["o"]?.object?["k"] == .number(1))
    #expect(json["s"]?.int == nil)
    #expect(json["a"]?[0] == .number(1))
    #expect(json["a"]?[5] == nil)
  }
}
