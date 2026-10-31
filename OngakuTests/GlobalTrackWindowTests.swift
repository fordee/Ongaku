//
//  GlobalTrackWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The Marker and Arrangement tracks in the project window.
@MainActor
struct GlobalTrackWindowTests {
  private let window: ProjectWindowModel
  private let bar = Tick.quarterNotes(4)

  init() {
    let regions = (0..<4).map { index in
      Region(name: "Part \(index + 1)", start: Tick.quarterNotes(32) * Int64(index), length: .quarterNotes(32), content: .midi(MIDISequence()))
    }
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      Track(name: "Keys", kind: .softwareInstrument, regions: regions)
    ])))
  }

  /// Key changes on the Signature track: adding one opens the key box without adding a
  /// change, choosing a key adds it, and dragging snaps to bars.
  @Test func keyChangesAreAddedAndMoved() throws {
    window.addKeyChange(atBarIndex: 8)
    #expect(window.isGlobalTracksVisible)
    #expect(window.keyEditPosition == bar * 8)
    #expect(window.project.keyChanges.isEmpty, "Nothing until a key is chosen")
    window.setKey(.cMajor, at: bar * 8)
    #expect(window.project.keyChanges.isEmpty, "The key already playing changes nothing")

    let gMajor = KeySignature(tonic: 7, mode: .major)
    window.setKey(gMajor, at: bar * 8)
    let change = try #require(window.project.keyChanges.first)
    #expect(change.key == gMajor && change.position == bar * 8)

    // Dropped near bar 13, it lands on it; it can't go to bar 1.
    window.moveKeyChange(change.id, to: bar * 12 + Tick.quarterNotes(1))
    #expect(window.project.keyChanges.first?.position == bar * 12)
    window.moveKeyChange(change.id, to: .zero)
    #expect(window.project.keyChanges.first?.position == bar, "Bar 1 holds the song's key")

    // What the LCD shows and changes: the key in effect at the playhead.
    #expect(window.project.keyStart(at: bar * 20) == bar)
    #expect(window.project.key(at: .zero) == .cMajor)

    window.removeKeyChange(change.id)
    #expect(window.project.keyChanges.isEmpty)
  }

  @Test func globalTracksMakeRoomUnderTheRuler() {
    let ruler = ProjectWindowModel.Layout.rulerHeight
    #expect(window.topHeight == ruler)
    window.toggleGlobalTracks()
    #expect(window.topHeight == ruler + ProjectWindowModel.globalTrackHeight * 4 + ProjectWindowModel.tempoTrackHeight)
  }

  @Test func markersAreCreatedAtThePlayheadAndNavigated() {
    window.engine.locate(to: bar * 2)
    window.createMarker()
    window.engine.locate(to: bar * 6)
    window.createMarker()
    window.createMarker()
    #expect(window.project.markers.map(\.name) == ["Marker 1", "Marker 2"], "Only one marker per position")
    #expect(window.isGlobalTracksVisible, "Creating a marker shows the Marker track")

    window.engine.locate(to: bar * 4)
    window.goToMarker(forward: true)
    #expect(window.engine.playheadPosition == bar * 6)
    window.goToMarker(forward: false)
    #expect(window.engine.playheadPosition == bar * 2)
  }

  @Test func newMarkersAreNumberedPastTheHighest() throws {
    for index in 1...3 {
      window.engine.locate(to: bar * Int64(index))
      window.createMarker()
    }
    let second = try #require(window.project.markers.first { $0.name == "Marker 2" })
    window.deleteMarker(second.id)
    window.engine.locate(to: bar * 8)
    window.createMarker()
    #expect(window.project.markers.map(\.name) == ["Marker 1", "Marker 3", "Marker 4"])
  }

  @Test func sectionsAreAddedEndToEndWithSuggestedNames() {
    window.addArrangementSection()
    window.addArrangementSection()
    #expect(window.project.arrangement.map(\.name) == ["Intro", "Verse"])
    #expect(window.project.arrangement.map(\.start) == [.zero, bar * 8])
    #expect(window.project.arrangement.allSatisfy { $0.length == bar * 8 })
    #expect(window.selectedSectionID == window.project.arrangement.last?.id)
  }

  @Test func draggingASectionReordersTheSong() throws {
    window.addArrangementSection()
    window.addArrangementSection()
    let verse = try #require(window.project.arrangement.last)
    // Dropped near the start: it goes first, and its region with it.
    window.moveSection(verse.id, droppedAt: bar)
    #expect(window.project.arrangement.map(\.name) == ["Verse", "Intro"])
    // Each part is eight bars: Part 1 was in the Intro and Part 2 in the Verse.
    #expect(window.project.tracks[0].regions.map(\.name) == ["Part 2", "Part 1", "Part 3", "Part 4"])
  }

  @Test func clickingASectionSelectsItsRegions() throws {
    window.addArrangementSection()
    let intro = try #require(window.project.arrangement.first)
    window.selectSection(intro.id)
    let names = window.project.tracks[0].regions.filter { window.selectedRegionIDs.contains($0.id) }.map(\.name)
    #expect(names == ["Part 1"])
  }

  @Test func sectionsCanBeRenamedResizedDuplicatedAndDeleted() throws {
    window.addArrangementSection()
    let intro = try #require(window.project.arrangement.first)
    window.renameSection(intro.id, to: "Chorus")
    #expect(window.project.arrangement.first?.name == "Chorus")
    window.resizeSection(intro.id, end: bar * 4)
    #expect(window.project.arrangement.first?.length == bar * 4)
    window.duplicateSection(intro.id)
    #expect(window.project.arrangement.count == 2)
    #expect(window.project.tracks[0].regions.count == 5, "Part 1 was copied")
    window.deleteSection(intro.id)
    #expect(window.project.arrangement.count == 1)
  }

  // MARK: - Tempo and signature

  @Test func tempoChangesLandOnTheGridAtWholeTempos() {
    window.addTempoChange(at: bar * 2 + Tick(13), bpm: 133.6)
    let change = window.project.tempoMap.tempoChanges.last
    #expect(change?.position == bar * 2)
    #expect(change?.bpm == 134)
    window.moveTempoChange(at: bar * 2, to: bar * 3, bpm: 90.2)
    #expect(window.project.tempoMap.tempoChanges.map(\.position) == [.zero, bar * 3])
    #expect(window.project.tempoMap.tempo(at: bar * 3) == 90)
    window.removeTempoChange(at: bar * 3)
    #expect(window.project.tempoMap.tempoChanges.count == 1)
  }

  @Test func theTempoTrackLeavesRoomAroundTheTempos() {
    #expect(window.tempoTrackRange == 100...140)
    window.addTempoChange(at: bar * 2, bpm: 200)
    #expect(window.tempoTrackRange == 110...210)
  }

  @Test func timeSignaturesGoToTheNearestBar() {
    let waltz = TimeSignature(beatsPerBar: 3, beatUnit: 4)
    window.setTimeSignature(waltz, atBarIndex: 4)
    // Just before bar 7 (index 6), whose bar lines the 3/4 has already moved.
    window.moveTimeSignature(fromBarIndex: 4, to: window.project.tempoMap.tickPosition(ofBarIndex: 6) - Tick(100))
    #expect(window.project.tempoMap.meterChanges.map(\.barIndex) == [0, 6])
    window.removeTimeSignature(atBarIndex: 6)
    #expect(window.project.tempoMap.meterChanges.count == 1)
  }

  @Test func theSignaturePlusAddsAChangeAtTheNextBarAndOpensIt() {
    // At the start of the song: bar 2, not bar 1's own meter again.
    window.addTimeSignatureAtPlayhead()
    #expect(window.project.tempoMap.meterChanges.map(\.barIndex) == [0, 1])
    #expect(window.signatureEditBarIndex == 1)
    // Inside bar 3: the bar after it.
    window.engine.locate(to: bar * 2 + Tick(100))
    window.addTimeSignatureAtPlayhead()
    #expect(window.signatureEditBarIndex == 3)
    // On a bar line: that bar.
    window.engine.locate(to: bar * 5)
    window.addTimeSignatureAtPlayhead()
    #expect(window.project.tempoMap.meterChanges.map(\.barIndex) == [0, 1, 3, 5])
    #expect(window.project.tempoMap.meterChanges.allSatisfy { $0.signature == .fourFour })
    #expect(window.isGlobalTracksVisible)
  }
}
