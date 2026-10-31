import Foundation

/// Parsed JSON at the process boundary; typed values are used everywhere inside.
public enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public subscript(key: String) -> JSON? {
    guard case .object(let fields) = self else { return nil }
    return fields[key]
  }

  public subscript(index: Int) -> JSON? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }

  public var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var number: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var int: Int? {
    guard case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 else {
      return nil
    }
    return Int(value)
  }

  public var bool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var array: [JSON]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var object: [String: JSON]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
}

extension JSON {
  /// Empty input is an empty object (CDP sends no body for a method with no result).
  /// Goes through JSONSerialization: a 1 MB DOM snapshot parses several times faster than with
  /// Codable.
  public static func parse(_ data: Data) -> JSON? {
    if data.isEmpty { return .object([:]) }
    guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    return convert(value)
  }

  private static func convert(_ value: Any) -> JSON? {
    switch value {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      return .number(number.doubleValue)
    case let string as String: return .string(string)
    case is NSNull: return .null
    case let items as [Any]: return .array(items.compactMap(convert))
    case let fields as [String: Any]: return .object(fields.compactMapValues(convert))
    default: return nil
    }
  }

  public func serialized() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
}

extension JSON: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
