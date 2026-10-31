//
//  TrackEditingTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Copying, pasting and repeating regions, duplicating tracks, and Logic's section edits
/// between the locators.
struct TrackEditingTests {
  private let bar = Tick.quarterNotes(4)

  private func midiRegion(_ name: String, at start: Tick, bars: Int64 = 1, notesAt beats: [Double] = []) -> Region {
    let notes = beats.map { MIDINote(pitch: 60, velocity: 100, start: .quarterNotes($0), length: .quarterNotes(0.5)) }
    return Region(name: name, start: start, length: bar * bars, content: .midi(MIDISequence(notes: notes)))
  }

  /// Keys (instrument) with regions at bars 1 and 3, Bass (instrument) with one at bar 2,
  /// and Vocal (audio) with one at bar 1.
  private func song() -> Project {
    let file = AudioFileReference(fileName: "Vocal.caf", sampleRate: 48_000, channelCount: 1, frameCount: 48_000 * 8)
    let keys = Track(name: "Keys", kind: .softwareInstrument, regions: [midiRegion("A", at: .zero), midiRegion("B", at: bar * 2)])
    let bass = Track(name: "Bass", kind: .softwareInstrument, regions: [midiRegion("C", at: bar)])
    let vocal = Track(
      name: "Vocal", kind: .audio,
      regions: [Region(name: "Vox", start: .zero, length: bar * 2, content: .audio(AudioRegionContent(fileID: file.id)))])
    return Project(tracks: [keys, bass, vocal], audioFiles: [file])
  }

  private func names(_ project: Project, track: Int) -> [String] {
    project.tracks[track].regions.map(\.name)
  }

  private func starts(_ project: Project, track: Int) -> [Tick] {
    project.tracks[track].regions.map(\.start)
  }

  // MARK: - Copy and paste

  @Test func pastingKeepsSpacingAndTracks() throws {
    var project = song()
    let order = project.tracks.map(\.id)
    let a = project.tracks[0].regions[0].id, c = project.tracks[1].regions[0].id
    let clipboard = try #require(RegionClipboard(copying: [a, c], from: project, trackOrder: order))
    #expect(clipboard.length == bar * 2)

    // Paste at bar 5 onto Keys: A lands there, C a bar later on Bass.
    let paste = PasteRegions(clipboard, at: bar * 4, onTrack: order[0], trackOrder: order)
    try paste.apply(to: &project)
    #expect(names(project, track: 0) == ["A", "B", "A"])
    #expect(starts(project, track: 0).last == bar * 4)
    #expect(starts(project, track: 1) == [bar, bar * 5])
    let pasted = Set(paste.newRegionIDs)
    #expect(pasted.count == 2 && pasted.allSatisfy { project.region(withID: $0) != nil }, "The copies are new regions")
  }

  @Test func pastingNeedsMatchingTracks() throws {
    var project = song()
    let order = project.tracks.map(\.id)
    let clipboard = try #require(RegionClipboard(copying: [project.tracks[1].regions[0].id], from: project, trackOrder: order))
    // MIDI onto the audio track.
    #expect(throws: EditError.self) {
      try PasteRegions(clipboard, at: .zero, onTrack: order[2], trackOrder: order).apply(to: &project)
    }
    // Two rows of regions pasted on the last track: nowhere for the second.
    let both = try #require(RegionClipboard(
      copying: [project.tracks[0].regions[0].id, project.tracks[1].regions[0].id], from: project, trackOrder: order))
    #expect(throws: EditError.self) {
      try PasteRegions(both, at: .zero, onTrack: order[1], trackOrder: order + []).apply(to: &project)
    }
  }

  @Test func audioPastesOnlyWhereItsFileIs() throws {
    let project = song()
    let order = project.tracks.map(\.id)
    let clipboard = try #require(RegionClipboard(copying: [project.tracks[2].regions[0].id], from: project, trackOrder: order))
    #expect(clipboard.audioFiles.count == 1)

    var same = project
    try PasteRegions(clipboard, at: bar * 4, onTrack: order[2], trackOrder: order).apply(to: &same)
    #expect(same.tracks[2].regions.count == 2)

    var other = Project(tracks: [Track(name: "Audio", kind: .audio)])
    #expect(throws: EditError.self) {
      try PasteRegions(clipboard, at: .zero, onTrack: other.tracks[0].id, trackOrder: other.tracks.map(\.id)).apply(to: &other)
    }
  }

  // MARK: - Repeat and duplicate

  @Test func repeatingLaysCopiesEndToEnd() throws {
    var project = song()
    // A (bar 1) and C (bar 2, on Bass) span two bars; three repeats follow at bars 3, 5 and 7.
    let command = RepeatRegions([project.tracks[0].regions[0].id, project.tracks[1].regions[0].id], times: 3)
    try command.apply(to: &project)
    #expect(starts(project, track: 0) == [.zero, bar * 2, bar * 2, bar * 4, bar * 6])
    #expect(starts(project, track: 1) == [bar, bar * 3, bar * 5, bar * 7])
    #expect(command.newRegionIDs.count == 6)
    #expect(command.newRegionIDs.allSatisfy { project.region(withID: $0) != nil })
  }

  @Test func duplicatingATrackCopiesEverythingWithNewIdentities() throws {
    var project = song()
    let eq = PluginReference(componentType: 1, componentSubType: 2, componentManufacturer: 3, name: "EQ")
    project.tracks[0].channel.inserts = [eq]
    let parameter = PluginParameter(pluginID: eq.id, address: 7, name: "Gain", initialValue: 0.5)
    var lane = AutomationLane(parameter: .plugin(parameter))
    lane.setPoints([AutomationPoint(position: .zero, value: 0.2)])
    project.tracks[0].automation = [lane]

    let command = DuplicateTrack(project.tracks[0].id)
    try command.apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Keys", "Keys 2", "Bass", "Vocal"])
    let original = project.tracks[0], copy = project.tracks[1]
    #expect(copy.id == command.copyID)
    #expect(copy.regions.map(\.name) == original.regions.map(\.name))
    #expect(Set(copy.regions.map(\.id)).isDisjoint(with: original.regions.map(\.id)))
    #expect(copy.channel.inserts.first?.id != eq.id, "Its own plug-in")
    guard case .plugin(let copied) = copy.automation.first?.parameter else { Issue.record("No plug-in lane"); return }
    #expect(copied.pluginID == copy.channel.inserts.first?.id, "Automation follows the new plug-in")

    try DuplicateTrack(project.tracks[1].id).apply(to: &project)
    #expect(project.tracks[2].name == "Keys 3")
  }

  // MARK: - Sections

  @Test func cuttingASectionClosesTheGap() throws {
    var project = song()
    project.markers = [Marker(name: "Verse", position: bar * 3)]
    // Cut bar 2: Keys' A ends where the cut starts, B moves from bar 3 to 2; Bass' C (all
    // of bar 2) goes; the Vocal (bars 1–2) is cut short to bar 1.
    try CutSection(bar..<(bar * 2)).apply(to: &project)
    #expect(names(project, track: 0) == ["A", "B"])
    #expect(starts(project, track: 0) == [.zero, bar])
    #expect(project.tracks[1].regions.isEmpty)
    #expect(project.tracks[2].regions.map(\.length) == [bar])
    #expect(project.markers.map(\.position) == [bar * 2])
  }

  @Test func cutsSplitRegionsAndKeepTheRightNotes() throws {
    // A two-bar region with notes on beats 1 and 6 (bar 2, beat 2); cutting bar 1 leaves the
    // second note, now in bar 1.
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [midiRegion("Riff", at: .zero, bars: 2, notesAt: [0, 5])])])
    try CutSection(.zero..<bar).apply(to: &project)
    let region = try #require(project.tracks[0].regions.first)
    #expect(project.tracks[0].regions.count == 1)
    #expect(region.start == .zero && region.length == bar)
    guard case .midi(let sequence) = region.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.start) == [.quarterNotes(1)])
  }

  @Test func insertingSilencePushesTheRestLater() throws {
    var project = song()
    try InsertSilence(bar..<(bar * 3)).apply(to: &project)
    #expect(starts(project, track: 0) == [.zero, bar * 4])
    #expect(starts(project, track: 1) == [bar * 3])
    // The Vocal crossed bar 2, so it's split there and its second half moves.
    #expect(starts(project, track: 2) == [.zero, bar * 3])
  }

  @Test func repeatingASectionCopiesItAndMakesRoom() throws {
    var project = song()
    // Repeat bars 1–2 twice: bars 3–6 get the copies, B (bar 3) moves to bar 7.
    try RepeatSection(.zero..<(bar * 2), times: 2).apply(to: &project)
    #expect(names(project, track: 0) == ["A", "A", "A", "B"])
    #expect(starts(project, track: 0) == [.zero, bar * 2, bar * 4, bar * 6])
    #expect(starts(project, track: 1) == [bar, bar * 3, bar * 5])
    #expect(starts(project, track: 2) == [.zero, bar * 2, bar * 4])
  }

  @Test func sectionsNeedARange() {
    var project = song()
    #expect(throws: EditError.self) { try CutSection(bar..<bar).apply(to: &project) }
  }
}
