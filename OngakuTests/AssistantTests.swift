//
//  AssistantTests.swift
//  OngakuTests
//

import Foundation
import FoundationModels
import OngakuCore
import Testing

@testable import Ongaku

/// The on-device assistant: Ongaku's agent tools offered to Apple's model.
@MainActor
struct AssistantTests {
  @Test func everyToolsSchemaConverts() throws {
    for tool in AgentToolbox.tools {
      _ = try AgentSchemaConversion.generationSchema(for: tool)
    }
  }

  @Test func theModelsArgumentsReachTheToolsAsJSON() throws {
    let content = try GeneratedContent(
      json: #"{"track": "Bass", "notes": [{"pitch": "C2", "start": 0, "length": 0.5}], "replace": null}"#)
    let arguments = AgentSchemaConversion.arguments(from: content)
    #expect(arguments["track"] == "Bass")
    #expect(arguments["notes"]?.arrayValue?.first?["pitch"] == "C2")
    #expect(arguments["notes"]?.arrayValue?.first?["length"]?.doubleValue == 0.5)
  }

  @Test func aToolCallIsAnUndoableAgentStep() async throws {
    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    let tool = try #require(AgentToolbox.tool(named: "set_tempo"))
    let adapter = try AgentToolAdapter(tool) { name, arguments in
      (try? await AgentToolbox.call(name, arguments: arguments, in: window).jsonString) ?? "failed"
    }
    undoManager.beginUndoGrouping()
    let reply = try await adapter.call(arguments: GeneratedContent(json: #"{"bpm": 96}"#))
    undoManager.endUndoGrouping()
    #expect(reply.contains("96"))
    #expect(window.project.tempoMap.tempo(at: .zero) == 96)
    #expect(undoManager.undoActionName == "Agent: Set Tempo")
  }

  @Test func unavailabilityIsExplained() {
    #expect(AssistantModel.explanation(of: .available) == nil)
    for reason in [SystemLanguageModel.Availability.UnavailableReason.appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady] {
      #expect(AssistantModel.explanation(of: .unavailable(reason))?.isEmpty == false)
    }
  }

  /// The three biggest tools, the guide and a song summary leave room in the model's context
  /// for the request, the tool calls and their results.
  @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
  func theBiggestToolsFitTheContext() async throws {
    let model = SystemLanguageModel.default
    let guide = try await model.tokenCount(for: Instructions(AgentToolbox.compactInstructions() + String(repeating: "x", count: 1_200)))
    var counts: [(String, Int)] = []
    for tool in AgentToolbox.tools {
      counts.append((tool.name, try await model.tokenCount(for: [AgentToolAdapter(tool) { _, _ in "" }])))
    }
    counts.sort { $0.1 > $1.1 }
    let picker = try await model.tokenCount(for: Instructions(AssistantModel.pickerInstructions))
    #expect(picker < model.contextSize / 3)
    let biggest = counts.prefix(3).map(\.1).reduce(0, +)
    print("Assistant tokens: picker \(picker), guide \(guide), biggest tools", counts.prefix(8).map { "\($0.0) \($0.1)" }, "context", model.contextSize)
    #expect(guide + biggest < model.contextSize * 2 / 3, "\(counts.prefix(3))")
  }

  /// An overflowing context is recognised, so the assistant can try again with less.
  @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
  func anOverflowingContextIsRecognised() async throws {
    let session = LanguageModelSession(instructions: String(repeating: "Bar 5 has a C major chord. ", count: 800))
    do {
      _ = try await session.respond(to: "Hello")
      Issue.record("It fit")
    } catch {
      #expect(AssistantModel.isContextOverflow(error), "\(String(reflecting: type(of: error))): \(String(reflecting: error))")
    }
  }

  /// With Apple Intelligence on: the model picks its tools and starts a song.
  @Test(.enabled(if: SystemLanguageModel.default.isAvailable))
  func theOnDeviceModelMakesASongStart() async throws {
    #expect(try await AssistantModel.toolNames(for: "Make the song faster, 128 BPM", earlier: nil).contains("set_tempo"))
    #expect(try await AssistantModel.toolNames(for: "Put a reverb on the vocals", earlier: nil).contains("add_effect"))

    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    let assistant = window.assistant
    assistant.draft = "Set the tempo to 100 BPM"
    assistant.send(in: window)
    while assistant.isResponding { try await Task.sleep(for: .milliseconds(100)) }
    #expect(window.project.tempoMap.tempo(at: .zero) == 100, "\(assistant.messages.map(\.text))")
    #expect(assistant.messages.last?.actions.contains("Set Tempo") == true)

    // Then something that takes a few tools in other areas.
    for request in ["Lay out an 8-bar Verse and an 8-bar Chorus", "Add a Drummer that plays every section"] {
      assistant.draft = request
      assistant.send(in: window)
      while assistant.isResponding { try await Task.sleep(for: .milliseconds(100)) }
    }
    print("Assistant replied:", assistant.messages.map { "\($0.role): \($0.text) \($0.actions)" })
    #expect(window.project.arrangement.count == 2, "\(assistant.messages.map(\.text))")
    #expect(window.project.tracks.contains { !$0.regions.isEmpty }, "\(assistant.messages.map(\.text))")
  }
}
