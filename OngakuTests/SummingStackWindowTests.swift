//
//  SummingStackWindowTests.swift
//  OngakuTests
//

import AppKit
import OngakuCore
@testable import Ongaku
import Testing

/// Summing stacks in the project window: selecting tracks, creating and collapsing stacks,
/// and how the tracks area counts rows.
@MainActor
struct SummingStackWindowTests {
  private let window: ProjectWindowModel
  private var tracks: [Track] { window.project.tracks }

  init() {
    let names = ["Kick", "Snare", "Hats", "Bass"]
    let tracks = names.map { name in
      Track(
        name: name, kind: .softwareInstrument,
        regions: [Region(name: name, start: .zero, length: Tick(3840), content: .midi(MIDISequence()))])
    }
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: tracks)))
  }

  private func id(_ name: String) -> Track.ID { tracks.first { $0.name == name }!.id }

  @Test func shiftAndCommandClicksSelectSeveralTracks() {
    window.selectTrack(id("Kick"))
    window.selectTrack(id("Hats"), modifiers: .shift)
    #expect(window.selectedTrackIDs == [id("Kick"), id("Snare"), id("Hats")])
    window.selectTrack(id("Snare"), modifiers: .command)
    #expect(window.selectedTrackIDs == [id("Kick"), id("Hats")])
    window.selectTrack(id("Bass"))
    #expect(window.selectedTrackIDs == [id("Bass")], "A plain click selects just that track")
  }

  @Test func theSelectionBecomesAStack() throws {
    window.selectTrack(id("Kick"))
    window.selectTrack(id("Hats"), modifiers: .shift)
    #expect(window.canCreateSummingStack)
    window.createSummingStack()
    let stack = try #require(tracks.first)
    #expect(stack.isSummingStack && stack.name == "Sum")
    #expect(tracks.map(\.name) == ["Sum", "Kick", "Snare", "Hats", "Bass"])
    #expect(window.selectedTrackID == stack.id)
    #expect(!window.canCreateSummingStack, "A stack can't go in another stack")
  }

  @Test func collapsingHidesTheSubtracks() throws {
    window.selectTrack(id("Kick"))
    window.selectTrack(id("Snare"), modifiers: .shift)
    window.createSummingStack()
    let stackID = try #require(tracks.first?.id)

    window.selectedTrackID = id("Kick")
    window.toggleStackCollapsed(stackID)
    #expect(window.displayedTracks.map(\.name) == ["Sum", "Hats", "Bass"])
    #expect(window.selectedTrackID == stackID, "The hidden subtrack's selection moves to the stack")
    window.toggleStackCollapsed(stackID)
    #expect(window.displayedTracks.count == 5)
  }

  @Test func regionsMoveByTheTracksShown() throws {
    window.selectTrack(id("Kick"))
    window.selectTrack(id("Snare"), modifiers: .shift)
    window.createSummingStack()
    let stackID = try #require(tracks.first?.id)
    window.toggleStackCollapsed(stackID)

    // Shown: Sum, Hats, Bass. Hats' region one row down lands on Bass.
    let hatsRegion = try #require(window.project.track(withID: id("Hats"))?.regions.first)
    window.selectedRegionIDs = [hatsRegion.id]
    window.moveSelection(by: .zero, trackOffset: 1)
    #expect(window.project.track(withID: id("Bass"))?.regions.map(\.id).contains(hatsRegion.id) == true)
  }

  @Test func newTracksJoinTheSelectedStack() throws {
    window.selectTrack(id("Kick"))
    window.createSummingStack()
    let stackID = try #require(tracks.first?.id)
    window.selectedTrackID = id("Kick")
    window.addTrack(.audio)
    let added = try #require(window.selectedTrack)
    #expect(added.stackID == stackID)
    #expect(added.channel.output == .track(stackID))
    #expect(window.project.stackMembers(of: stackID).map(\.name) == ["Kick", added.name])
  }

  @Test func theOutputMenuOffersAuxesThatDontLoop() throws {
    window.selectTrack(id("Kick"))
    window.createSummingStack()
    let stackID = try #require(tracks.first?.id)
    #expect(window.outputDestinations(for: id("Bass")).map(\.id) == [stackID])
    #expect(window.outputDestinations(for: stackID).isEmpty, "A stack can't output to itself")
    window.setOutput(of: id("Bass"), to: .track(stackID))
    #expect(window.project.track(withID: id("Bass"))?.channel.output == .track(stackID))
  }
}

/// Mixer groups from the window: the Group slot and dragging grouped controls.
@MainActor
struct MixerGroupWindowTests {
  @Test func newGroupsTakeTheSelectionAndTheNextNumber() {
    let tracks = ["Kick", "Snare", "Bass"].map { Track(name: $0, kind: .softwareInstrument) }
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: tracks)))
    window.selectedTrackIDs = [tracks[0].id, tracks[1].id]
    window.createGroup(with: tracks[0].id)
    #expect(window.project.groups.map(\.id) == [1])
    #expect(window.project.tracks.map(\.groupID) == [1, 1, nil])
    window.createGroup(with: tracks[2].id)
    #expect(window.project.tracks.last?.groupID == 2, "A track that isn't selected is grouped on its own")
  }

  @Test func faderMovesCarryToTheGroup() {
    let tracks = ["Kick", "Snare"].map { Track(name: $0, kind: .softwareInstrument) }
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: tracks)))
    window.selectedTrackIDs = Set(tracks.map(\.id))
    window.createGroup(with: tracks[0].id)
    window.setChannel(tracks[0].id, actionName: "Volume") { $0.volume = -12 }
    window.setChannel(tracks[0].id, actionName: "Mute") { $0.isMuted = true }
    #expect(window.project.tracks[1].channel.volume == -12)
    #expect(window.project.tracks[1].channel.isMuted)
  }
}
