//
//  GlueRegionsTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Joining regions with the Glue tool or Edit › Join Regions.
struct GlueRegionsTests {
  private func midiRegion(_ name: String, at start: Tick, length: Tick, notes: [MIDINote], isMuted: Bool = false) -> Region {
    Region(name: name, start: start, length: length, isMuted: isMuted, content: .midi(MIDISequence(notes: notes)))
  }

  @Test func midiRegionsJoinWithTheirNotesInPlace() throws {
    let a = midiRegion("A", at: .zero, length: .quarterNotes(4), notes: [
      MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1)),
      // Outside the region, so it never played: left out.
      MIDINote(pitch: 61, start: .quarterNotes(5), length: .quarterNotes(1)),
    ])
    let b = midiRegion("B", at: .quarterNotes(8), length: .quarterNotes(4), notes: [
      MIDINote(pitch: 64, start: .quarterNotes(1), length: .quarterNotes(1))
    ])
    var track = Track(name: "Keys", kind: .softwareInstrument, regions: [a, b])
    track.channel.instrument = nil
    var project = Project(tracks: [track])
    try GlueRegions([a.id, b.id]).apply(to: &project)

    let regions = project.tracks[0].regions
    #expect(regions.count == 1)
    let joined = try #require(regions.first)
    #expect(joined.id == a.id)
    #expect(joined.name == "A")
    #expect(joined.start == .zero)
    #expect(joined.length == .quarterNotes(12))
    guard case .midi(let sequence) = joined.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [60, 64])
    #expect(sequence.notes.last?.start == .quarterNotes(9))
  }

  @Test func mutedRegionsAddNothing() throws {
    let a = midiRegion("A", at: .zero, length: .quarterNotes(4), notes: [MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))])
    let b = midiRegion("B", at: .quarterNotes(4), length: .quarterNotes(4), notes: [
      MIDINote(pitch: 64, start: .zero, length: .quarterNotes(1))
    ], isMuted: true)
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [a, b])])
    try GlueRegions([a.id, b.id]).apply(to: &project)
    guard case .midi(let sequence) = project.tracks[0].regions[0].content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [60])
    #expect(!project.tracks[0].regions[0].isMuted)
  }

  @Test func eachTrackJoinsSeparately() throws {
    let a1 = midiRegion("A1", at: .zero, length: .quarterNotes(4), notes: [])
    let a2 = midiRegion("A2", at: .quarterNotes(4), length: .quarterNotes(4), notes: [])
    let b1 = midiRegion("B1", at: .zero, length: .quarterNotes(4), notes: [])
    let b2 = midiRegion("B2", at: .quarterNotes(8), length: .quarterNotes(4), notes: [])
    var project = Project(tracks: [
      Track(name: "A", kind: .softwareInstrument, regions: [a1, a2]),
      Track(name: "B", kind: .softwareInstrument, regions: [b1, b2]),
    ])
    try GlueRegions([a1.id, a2.id, b1.id, b2.id]).apply(to: &project)
    #expect(project.tracks.map(\.regions.count) == [1, 1])
    #expect(project.tracks[1].regions[0].length == .quarterNotes(12))
  }

  @Test func oneRegionPerTrackIsNothingToJoin() {
    let a = midiRegion("A", at: .zero, length: .quarterNotes(4), notes: [])
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [a])])
    #expect(throws: EditError.self) { try GlueRegions([a.id]).apply(to: &project) }
  }

  // MARK: - Audio

  private func audioProject() throws -> (Project, Region.ID) {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
    let region = Region(name: "Take", start: .zero, length: .quarterNotes(8), content: .audio(AudioRegionContent(fileID: file.id)))
    return (Project(tracks: [Track(name: "Audio", kind: .audio, regions: [region])], audioFiles: [file]), region.id)
  }

  @Test func splitAudioJoinsBackUp() throws {
    var (project, id) = try audioProject()
    let split = SplitRegion(id, at: .quarterNotes(3))
    try split.apply(to: &project)
    try GlueRegions([id, split.newRegionID]).apply(to: &project)
    #expect(project.tracks[0].regions.count == 1)
    #expect(project.tracks[0].regions[0].length == .quarterNotes(8))
    #expect(project.tracks[0].regions[0].content == .audio(AudioRegionContent(fileID: project.audioFiles[0].id)))
  }

  @Test func audioThatWouldNeedANewFileIsRefused() throws {
    var (project, id) = try audioProject()
    let split = SplitRegion(id, at: .quarterNotes(3))
    try split.apply(to: &project)
    // Moving the second piece means the two no longer play one stretch of the file.
    try MoveRegion(split.newRegionID, to: .quarterNotes(4)).apply(to: &project)
    #expect(throws: EditError.self) { try GlueRegions([id, split.newRegionID]).apply(to: &project) }
  }
}
