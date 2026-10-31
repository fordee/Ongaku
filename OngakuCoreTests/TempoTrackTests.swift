//
//  TempoTrackTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Editing tempo and time signature changes on the global tracks, and how playback follows them.
struct TempoTrackTests {
  private let bar = Tick.quarterNotes(4)

  @Test func tempoChangesMoveAndChange() throws {
    var project = Project()
    try SetTempo(140, at: bar * 4).apply(to: &project)
    try UpdateTempoChange(at: bar * 4, to: bar * 8, bpm: 150).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.map(\.position) == [.zero, bar * 8])
    #expect(project.tempoMap.tempo(at: bar * 8) == 150)
    #expect(project.tempoMap.tempo(at: bar * 4) == 120)
  }

  @Test func theFirstTempoStaysAtTheStart() throws {
    var project = Project()
    try UpdateTempoChange(at: .zero, to: bar * 2, bpm: 90).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.map(\.position) == [.zero])
    #expect(project.tempoMap.tempo(at: .zero) == 90)
    #expect(throws: EditError.self) { try RemoveTempoChange(at: .zero).apply(to: &project) }
  }

  @Test func movingOntoAnotherChangeReplacesIt() throws {
    var project = Project()
    try SetTempo(140, at: bar * 4).apply(to: &project)
    try SetTempo(100, at: bar * 8).apply(to: &project)
    try UpdateTempoChange(at: bar * 8, to: bar * 4, bpm: 100).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.map(\.bpm) == [120, 100])
  }

  @Test func tempoChangesCanBeRemoved() throws {
    var project = Project()
    try SetTempo(140, at: bar * 4).apply(to: &project)
    try RemoveTempoChange(at: bar * 4).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.count == 1)
  }

  @Test func timeSignaturesMoveBetweenBars() throws {
    var project = Project()
    let waltz = TimeSignature(beatsPerBar: 3, beatUnit: 4)
    try SetTimeSignature(waltz, atBarIndex: 4).apply(to: &project)
    try MoveTimeSignatureChange(fromBarIndex: 4, toBarIndex: 8).apply(to: &project)
    #expect(project.tempoMap.meterChanges.map(\.barIndex) == [0, 8])
    #expect(project.tempoMap.timeSignature(atBarIndex: 8) == waltz)
    #expect(throws: EditError.self) { try MoveTimeSignatureChange(fromBarIndex: 0, toBarIndex: 2).apply(to: &project) }
    try RemoveTimeSignatureChange(atBarIndex: 8).apply(to: &project)
    #expect(project.tempoMap.meterChanges.count == 1)
    #expect(throws: EditError.self) { try RemoveTimeSignatureChange(atBarIndex: 0).apply(to: &project) }
  }

  @Test func notesAfterATempoChangePlayAtTheNewTempo() throws {
    // 120 BPM for four beats (2 s), then 60 BPM: a note on beat 6 is two beats later at 1 s each.
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.regions = [Region(name: "Notes", start: .zero, length: bar * 2, content: .midi(MIDISequence(notes: [
      MIDINote(pitch: 60, start: .quarterNotes(5), length: .quarterNotes(1))
    ])))]
    var project = Project(tracks: [keys])
    try SetTempo(60, at: bar).apply(to: &project)
    let noteOn = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10).first { $0.bytes.first == 0x90 }
    #expect(noteOn?.playbackTime == 3)
  }
}
