//
//  AsPlayedNotesTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Joining regions and exporting MIDI files keep the notes as they play, with each region's
/// transpose, velocity and quantize; and frozen tracks keep their MIDI effects.
@MainActor
struct AsPlayedNotesTests {
  private let bar = Tick(3840)

  private func region(_ name: String, at start: Tick, transpose: Int = 0) -> Region {
    let note = MIDINote(pitch: 60, velocity: 80, start: Tick(10), length: Tick(480))
    return Region(name: name, start: start, length: bar, content: .midi(MIDISequence(notes: [note])), transpose: transpose)
  }

  private func pitches(_ region: Region?) -> [Int] {
    guard case .midi(let sequence) = region?.content else { return [] }
    return sequence.notes.map(\.pitch)
  }

  @Test func joiningRegionsWithDifferentTransposesKeepsWhatTheyPlay() throws {
    let first = region("A", at: .zero), second = region("B", at: bar, transpose: 7)
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [first, second])])
    try JoinRegions([first.id, second.id]).apply(to: &project)
    let joined = project.region(withID: first.id)
    #expect(pitches(joined) == [60, 67], "The second region's transpose is written into its note")
    #expect(joined?.transpose == 0)
  }

  @Test func joiningRegionsWithTheSameSettingsKeepsThemAsSettings() throws {
    var first = region("A", at: .zero, transpose: 5), second = region("B", at: bar, transpose: 5)
    first.playbackQuantize = Tick(240)
    second.playbackQuantize = Tick(240)
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [first, second])])
    try JoinRegions([first.id, second.id]).apply(to: &project)
    let joined = project.region(withID: first.id)
    #expect(pitches(joined) == [60, 60] && joined?.transpose == 5 && joined?.playbackQuantize == Tick(240))
  }

  @Test func midiFilesHoldTheNotesAsTheyPlay() throws {
    var played = region("A", at: .zero, transpose: 12)
    played.velocityOffset = 20
    played.playbackQuantize = Tick(240)
    let project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [played])])
    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(project))
    guard case .midi(let sequence) = contents.tracks.first?.regions.first?.content, let note = sequence.notes.first else {
      Issue.record("Expected a note")
      return
    }
    #expect(note.pitch == 72 && note.velocity == 100)
    #expect(note.start + (contents.tracks.first?.regions.first?.start ?? .zero) == .zero, "Quantized to the grid")
  }

  @Test func frozenTracksKeepTheirMIDIEffects() throws {
    let track = Track(name: "Keys", kind: .softwareInstrument, regions: [region("A", at: .zero)])
    let editor = ProjectEditor(project: Project(tracks: [track]))
    let file = AudioFileReference(fileName: "Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    try editor.perform(FreezeTrack(track.id, file: file), undoManager: nil)
    #expect(throws: EditError.self) {
      try editor.perform(AddMIDIEffect(MIDIEffect(.transposer(Transposer())), to: track.id), undoManager: nil)
    }
  }

  @Test func frozenTracksLockTheirInstrumentsAutomationButNotTheirVolume() throws {
    var track = Track(name: "Synth", kind: .softwareInstrument, regions: [region("A", at: .zero)])
    let synth = OngakuInstrument.retroSynth.makeReference()
    track.channel.instrument = .audioUnit(synth)
    let editor = ProjectEditor(project: Project(tracks: [track]))
    let file = AudioFileReference(fileName: "Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    try editor.perform(FreezeTrack(track.id, file: file), undoManager: nil)

    let cutoff = AutomationParameter.plugin(PluginParameter(pluginID: synth.id, address: 407, name: "Cutoff"))
    let point = AutomationPoint(position: .zero, value: 0.2)
    #expect(throws: EditError.self, "The freeze file plays the instrument's automation") {
      try editor.perform(AddAutomationPoints([point], to: cutoff, on: track.id), undoManager: nil)
    }
    try editor.perform(AddAutomationPoints([point], to: .volume, on: track.id), undoManager: nil)
  }
}
