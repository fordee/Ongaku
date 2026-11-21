//
//  AgentToolAdapter.swift
//  Ongaku
//

import Foundation
import FoundationModels
import OngakuCore

/// One of Ongaku's agent tools, offered to the on-device model.
///
/// The model sees the same name and description MCP clients see, and arguments shaped by the
/// tool's JSON Schema (converted to a generation schema). Calls run on the window through
/// `AgentToolbox.call`, so each change is an undoable "Agent: …" step, as from MCP. Failures
/// go back to the model as text it can act on.
nonisolated struct AgentToolAdapter: Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema
  /// Runs the tool by name with JSON arguments, returning what the model reads back.
  /// Throwing ends the request.
  let run: @Sendable (String, [String: AgentValue]) async throws -> String

  init(_ tool: AgentTool, run: @escaping @Sendable (String, [String: AgentValue]) async throws -> String) throws {
    name = tool.name
    description = AgentSchemaConversion.firstSentence(of: tool.description)
    parameters = try AgentSchemaConversion.generationSchema(for: tool)
    self.run = run
  }

  func call(arguments: GeneratedContent) async throws -> String {
    try await run(name, AgentSchemaConversion.arguments(from: arguments))
  }
}

/// Converts between the agent tools' JSON Schemas and values and FoundationModels' types.
nonisolated enum AgentSchemaConversion {
  /// The tool's argument object as a generation schema. Fields that take text or a number
  /// (positions, tracks, pitches) become text: the tools read numbers from text too.
  static func generationSchema(for tool: AgentTool) throws -> GenerationSchema {
    var dependencies: [DynamicGenerationSchema] = []
    let root = dynamicSchema(tool.inputSchema, name: tool.name, description: nil, dependencies: &dependencies)
    return try GenerationSchema(root: root, dependencies: dependencies)
  }

  private static func dynamicSchema(
    _ schema: AgentValue, name: String, description: String?, dependencies: inout [DynamicGenerationSchema]
  ) -> DynamicGenerationSchema {
    // `description` comes from the caller: a property's is on the property, not repeated here.
    if let choices = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
      return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
    }
    switch types(of: schema) {
    case ["object"]:
      let properties = schema["properties"]?.objectValue ?? [:]
      let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      return DynamicGenerationSchema(
        name: name, description: description,
        properties: properties.keys.sorted().map { key in
          let property = properties[key] ?? .object([:])
          return DynamicGenerationSchema.Property(
            name: key, description: property["description"]?.stringValue.map(firstSentence),
            schema: dynamicSchema(property, name: "\(name)_\(key)", description: nil, dependencies: &dependencies),
            isOptional: !required.contains(key))
        })
    case ["array"]:
      let itemSchema = schema["items"] ?? ["type": "string"]
      let items = dynamicSchema(
        itemSchema, name: "\(name)_item", description: itemSchema["description"]?.stringValue.map(firstSentence),
        dependencies: &dependencies)
      return DynamicGenerationSchema(arrayOf: items)
    case ["integer"]:
      return DynamicGenerationSchema(type: Int.self)
    case ["number"]:
      return DynamicGenerationSchema(type: Double.self)
    case ["boolean"]:
      return DynamicGenerationSchema(type: Bool.self)
    default:
      return DynamicGenerationSchema(type: String.self)
    }
  }

  /// The on-device model's context is small, and the tools' descriptions are written for
  /// big models: it gets their first sentences.
  static func firstSentence(of text: String) -> String {
    var end = text.startIndex
    while let dot = text[end...].firstIndex(of: ".") {
      let next = text.index(after: dot)
      // A full stop then a space or the end, outside quotes ("5:2.5", "e.g." stay).
      if next == text.endIndex || text[next] == " " || text[next] == "\n" {
        let sentence = String(text[...dot])
        if sentence.filter({ $0 == "\"" }).count.isMultiple(of: 2) { return sentence }
      }
      end = next
    }
    return text
  }

  private static func types(of schema: AgentValue) -> [String] {
    switch schema["type"] {
    case .string(let type): [type]
    case .array(let types): types.compactMap(\.stringValue)
    default: []
    }
  }

  /// The model's arguments as the tools take them.
  static func arguments(from content: GeneratedContent) -> [String: AgentValue] {
    guard let data = content.jsonString.data(using: .utf8),
      let value = try? JSONDecoder().decode(AgentValue.self, from: data)
    else { return [:] }
    // Optional properties the model leaves empty arrive as nulls: the tools treat a null as missing.
    return value.objectValue ?? [:]
  }
}
