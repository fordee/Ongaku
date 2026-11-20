//
//  GeneratedRegionTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// A region's one source (take folder, pattern, drummer or player), and generated regions
/// playing again after any edit that changes what they're generated from.
@MainActor
struct GeneratedRegionTests {
  private let bar = Tick(3840)

  private func perform(_ command: some EditCommand, on editor: ProjectEditor) throws {
    // No undo manager: these tests only look at the result.
    try editor.perform(command, undoManager: nil)
  }

  /// A song with a chord per bar and a one-bar bass player region at the start.
  private func playerSong(chords: [String]) -> (Project, Region.ID) {
    var project = Project()
    project.chords = chords.enumerated().map { index, name in
      ChordChange(position: bar * Int64(index), chord: Chord(name: name)!)
    }
    var region = Region(
      name: "Bass", start: .zero, length: bar, content: .midi(MIDISequence()),
      player: PlayerPerformance(style: .rootNotes, complexity: 0, leadsIntoNext: false, seed: 1))
    region.renderPlayer(in: project)
    project.tracks = [Track(name: "Bass", kind: .softwareInstrument, regions: [region])]
    return (project, region.id)
  }

  private func lowestPitchClass(_ project: Project, _ regionID: Region.ID) -> Int? {
    guard case .midi(let sequence) = project.region(withID: regionID)?.content else { return nil }
    return sequence.notes.min { $0.start < $1.start }.map { $0.pitch % 12 }
  }

  @Test func aRegionHasOneSource() {
    var region = Region(name: "Drums", start: .zero, length: bar, content: .midi(MIDISequence()))
    region.drummer = DrummerPerformance()
    #expect(region.isGenerated && region.drummer != nil)

    region.pattern = nil
    #expect(region.drummer != nil, "Clearing another kind leaves the drummer alone")

    let take = Take(name: "Take 1", content: region.content)
    region.takeFolder = TakeFolder(takes: [take], playing: take.id, length: bar)
    #expect(region.drummer == nil && region.takeFolder != nil, "Packing into a take folder replaces the drummer")
    #expect(!region.isGenerated)

    region.takeFolder = nil
    #expect(region.source == nil)
  }

  @Test func songsAreSavedAsBefore() throws {
    let (project, regionID) = playerSong(chords: ["C"])
    let data = try ProjectArchive.encode(project)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tracks = try #require(json["tracks"] as? [[String: Any]])
    let region = try #require((tracks[0]["regions"] as? [[String: Any]])?.first)
    #expect(region["player"] != nil && region["source"] == nil, "Each kind keeps its own key")
    #expect(region["drummer"] == nil && region["pattern"] == nil && region["takeFolder"] == nil)

    let read = try ProjectArchive.decode(data)
    #expect(read.region(withID: regionID) == project.region(withID: regionID))
  }

  @Test func movedPlayerRegionsPlayTheChordsWhereTheyLand() throws {
    let (project, regionID) = playerSong(chords: ["C", "Am", "F", "G"])
    #expect(lowestPitchClass(project, regionID) == 0)
    let editor = ProjectEditor(project: project)

    try perform(MoveRegion(regionID, to: bar * 2), on: editor)
    #expect(lowestPitchClass(editor.project, regionID) == 5, "Over the F, it plays F")
  }

  @Test func pastedAndRepeatedPlayerRegionsFollowTheChordsToo() throws {
    let (project, regionID) = playerSong(chords: ["C", "Am", "F", "G"])
    let editor = ProjectEditor(project: project)

    try perform(RepeatRegions([regionID], times: 3), on: editor)
    let regions = editor.project.tracks[0].regions.sorted { $0.start < $1.start }
    #expect(regions.count == 4)
    #expect(regions.map { lowestPitchClass(editor.project, $0.id) } == [0, 9, 5, 7], "C, A, F and G")
  }

  @Test func tempoAndChordEditsLeaveUnchangedRegionsAlone() throws {
    let (project, regionID) = playerSong(chords: ["C"])
    let editor = ProjectEditor(project: project)
    let before = editor.project.region(withID: regionID)

    try perform(SetTempo(96), on: editor)
    #expect(editor.project.region(withID: regionID) == before, "Rendering again gives the same notes")
  }

  @Test func frozenPlayerTracksDontStopTempoChanges() throws {
    let (project, _) = playerSong(chords: ["C", "F"])
    let editor = ProjectEditor(project: project)
    let file = AudioFileReference(fileName: "Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    try perform(FreezeTrack(project.tracks[0].id, file: file), on: editor)

    try perform(SetTempo(140), on: editor)
    #expect(editor.project.tempoMap.tempo(at: .zero) == 140)
  }
}
