//
//  ManualDemoTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The manual's demo song sets up every scene its screenshots need (ManualScreenshotUITests
/// takes them; this checks the set-ups without opening windows).
@MainActor
@Suite(.serialized)
struct ManualDemoTests {
  @Test(arguments: ManualDemo.Scene.allCases)
  func everySceneSetsUp(_ scene: ManualDemo.Scene) async throws {
    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    defer { window.engine.shutDown() }
    await ManualDemo.setUp(window, for: scene)
    #expect(window.errorMessage == nil, "\(scene): \(window.errorMessage ?? "")")
    let names = window.project.tracks.map(\.name)
    for name in ["Keys", "Lead", "Vocals", "Drum Loop", "Reverb", "Bass Player", "Drummer"] {
      #expect(names.contains(name), "\(scene): no \(name) track in \(names)")
    }
    #expect(!window.project.chords.isEmpty)
    #expect(window.selectedTrackID != nil, "\(scene): a track is selected")

    switch scene {
    case .pianoRoll, .pianoRollHeader, .pitchBend, .stepSequencer:
      #expect(window.isEditorVisible, "\(scene): the editor is open")
    case .overview, .controlBar, .sends:
      #expect(window.bottomPane == .mixer)
    case .stackExpanded, .stackCollapsed:
      #expect(window.project.tracks.contains { $0.isSummingStack }, "The drums are stacked")
    case .smartTempo:
      let loop = try #require(window.project.tracks.first { $0.name == "Drum Loop" }?.regions.first)
      let tempo = try #require(window.detectedTempos[loop.id], "The loop's tempo is found")
      #expect(abs(tempo.bpm - 100) < 2, "The loop is at 100 BPM, found \(tempo.bpm)")
    case .regions:
      #expect(window.project.tracks.flatMap(\.regions).contains { $0.isMuted }, "One region is muted")
    default:
      break
    }
  }
}
