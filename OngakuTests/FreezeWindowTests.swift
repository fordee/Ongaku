//
//  FreezeWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
@testable import Ongaku
import Testing

/// Freezing from the project window: the Freeze button renders in the background, then
/// the track plays the file and its regions are locked.
@MainActor
@Suite(.serialized)
struct FreezeWindowTests {
  private let window: ProjectWindowModel
  private let trackID: Track.ID

  init() {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [
      MIDINote(pitch: 60, velocity: 100, start: .zero, length: .quarterNotes(1))
    ])))]
    trackID = keys.id
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
  }

  private var track: Track? { window.project.track(withID: trackID) }

  @Test func theFreezeButtonFreezesAndUnfreezes() async throws {
    window.toggleFreeze(trackID)
    #expect(window.freezeProgress[trackID] != nil, "The header shows the render's progress")
    await window.freezeTasks[trackID]?.value

    let file = try #require(track?.freezeFile, "\(window.errorMessage ?? "")")
    let url = try #require(window.document.url(for: file))
    #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    #expect(window.freezeProgress[trackID] == nil)
    #expect(window.freezeTasks[trackID] == nil)

    window.toggleFreeze(trackID)
    #expect(track?.isFrozen == false)
  }

  @Test func editingAFrozenTrackExplainsWhy() async throws {
    window.freezeTrack(trackID)
    await window.freezeTasks[trackID]?.value
    let region = try #require(track?.regions.first)
    window.perform(MoveRegion(region.id, to: .quarterNotes(2)))
    #expect(track?.regions.first?.start == .zero)
    #expect(window.errorMessage?.contains("frozen") == true)
  }

  @Test func clickingAgainStopsTheFreeze() async {
    window.toggleFreeze(trackID)
    window.toggleFreeze(trackID)
    await window.freezeTasks[trackID]?.value
    #expect(track?.isFrozen == false)
    #expect(window.errorMessage == nil, "Stopping isn't an error")
  }

  @Test func theTrackMenuFreezesTheSelection() async {
    window.selectedTrackID = trackID
    #expect(window.canFreezeSelectedTracks)
    #expect(!window.selectedTracksAreFrozen)
    window.toggleFreezeSelectedTracks()
    await window.freezeTasks[trackID]?.value
    #expect(window.selectedTracksAreFrozen)
    window.toggleFreezeSelectedTracks()
    #expect(track?.isFrozen == false)
  }
}
