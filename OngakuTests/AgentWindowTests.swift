//
//  AgentWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The agent tools that need the real engine, in a real project window: live plug-in
/// parameters, rendering the mix to measure it, bouncing, and mastering. Everything renders
/// offline, so nothing is heard.
@MainActor
@Suite(.serialized)
struct AgentWindowTests {
  /// A 32-second song (two 8-bar sections at 120 BPM) with a drummer and a keyboard player.
  private func song() async throws -> ProjectWindowModel {
    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    for (name, arguments) in [
      ("set_arrangement", ["sections": [["name": "Verse", "bars": 8], ["name": "Chorus", "bars": 8]]]),
      ("set_chords", ["bars": ["C", "Am", "F", "G"], "to": "17"]),
      ("add_drummer", ["style": "pop"]),
      ("add_session_player", ["instrument": "keys", "style": "blockChords"]),
    ] as [(String, [String: AgentValue])] {
      _ = try await AgentToolbox.call(name, arguments: arguments, in: window)
    }
    return window
  }

  @Test func effectParametersAreReadAndSetOnTheLivePlugin() async throws {
    let window = try await song()
    defer { window.engine.shutDown() }
    let added = try await AgentToolbox.call("add_effect", arguments: ["track": "Drummer", "effect": "Apple Delay"], in: window)
    let lines = added["parameters"]?.arrayValue ?? []
    #expect(!lines.isEmpty, "\(added)")

    let drummer = try #require(window.project.tracks.first { $0.name == "Drummer" })
    let plugin = try #require(drummer.channel.inserts.first)
    let parameter = try #require(window.parameters(ofPlugin: plugin.id, on: drummer.id)?.first { $0.choices == nil })
    let target = parameter.minimum + (parameter.maximum - parameter.minimum) * 0.25
    _ = try await AgentToolbox.call(
      "set_effect", arguments: ["track": "Drummer", "effect": "Apple Delay", "parameters": [parameter.name: .double(target)]], in: window)
    let changed = try #require(window.parameters(ofPlugin: plugin.id, on: drummer.id)?.first { $0.address == parameter.address })
    #expect(abs(changed.value - target) < (parameter.maximum - parameter.minimum) * 0.01)
    #expect(window.project.track(withID: drummer.id)?.channel.inserts.first?.state != nil, "The settings are stored in the song")
  }

  @Test func theMixIsRenderedAndMeasured() async throws {
    let window = try await song()
    defer { window.engine.shutDown() }
    let analysis = try await AgentToolbox.call("analyze_mix", arguments: [:], in: window)
    let seconds = try #require(analysis["seconds"]?.doubleValue)
    #expect(abs(seconds - 32) < 1)
    let loudness = try #require(analysis["song"]?["loudnessLufs"]?.doubleValue, "\(analysis)")
    #expect((-60 ... 0).contains(loudness))
    #expect(analysis["sections"]?.arrayValue?.count == 2)
  }

  @Test func aBounceLandsInTheMusicFolder() async throws {
    let window = try await song()
    defer { window.engine.shutDown() }
    let result = try await AgentToolbox.call("bounce", arguments: ["from": 1, "to": 3], in: window)
    let path = try #require(result["path"]?.stringValue)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(path.contains("Ongaku Studio/Bounces"))
    // Two bars at 120 BPM, and the tail of the reverb and delay.
    #expect((4..<7).contains(result["seconds"]?.doubleValue ?? 0))
  }

  @Test func masteringListensAndReportsWhatItFound() async throws {
    let window = try await song()
    defer { window.engine.shutDown() }
    let result = try await AgentToolbox.call("master_song", arguments: [:], in: window)
    #expect(result["loudnessLufs"]?.doubleValue != nil, "\(result)")
    #expect(window.project.stereoOutInserts.contains { OngakuEffect($0) == .mastering })
  }
}
