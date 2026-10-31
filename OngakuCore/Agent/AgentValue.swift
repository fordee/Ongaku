//
//  AgentValue.swift
//  OngakuCore
//

import Foundation

/// A JSON value, for what agents send to Ongaku's tools and get back.
///
/// Core has its own rather than the MCP SDK's so the tools don't depend on any one way of
/// reaching them: the app's MCP server converts to and from this, and an on-device assistant
/// could call the tools directly.
public enum AgentValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([AgentValue])
  case object([String: AgentValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([AgentValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: AgentValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  /// Whole numbers, including doubles with no fraction and numeric strings ("3").
  public var intValue: Int? {
    switch self {
    case .int(let value): value
    case .double(let value) where value.rounded() == value && abs(value) < 1e15: Int(value)
    case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .int(let value): Double(value)
    case .double(let value): value
    case .string(let value): Double(value.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }

  public var boolValue: Bool? {
    switch self {
    case .bool(let value): value
    case .string(let value) where ["true", "false"].contains(value.lowercased()): value.lowercased() == "true"
    default: nil
    }
  }

  public var arrayValue: [AgentValue]? {
    if case .array(let value) = self { value } else { nil }
  }

  public var objectValue: [String: AgentValue]? {
    if case .object(let value) = self { value } else { nil }
  }

  public subscript(key: String) -> AgentValue? {
    objectValue?[key]
  }

  /// Compact JSON with sorted keys, which is what tools return as text.
  public var jsonString: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

extension AgentValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: AgentValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, AgentValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}

extension AgentValue {
  /// A number as agents read it: whole numbers without ".0", others to three places.
  static func number(_ value: Double) -> AgentValue {
    if value.rounded() == value, abs(value) < 1e15 { return .int(Int(value)) }
    return .double((value * 1000).rounded() / 1000)
  }

  /// `value`, or null when there's none.
  static func optional(_ value: String?) -> AgentValue {
    value.map { .string($0) } ?? .null
  }
}
