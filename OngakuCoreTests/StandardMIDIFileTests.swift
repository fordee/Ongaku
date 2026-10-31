//
//  StandardMIDIFileTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct StandardMIDIFileTests {
  /// A hand-built format 0 file at 96 ticks per quarter note: 3/4, 100 BPM, a track name,
  /// a program change to Vibraphone, two notes using running status and a velocity-0 note-off.
  private let formatZeroFile: [UInt8] = [
    0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,  // MThd, format 0, 1 track, 96 PPQ
    0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 44,  // MTrk, 44 bytes
    0x00, 0xFF, 0x03, 0x04, 0x56, 0x69, 0x62, 0x65,  // track name "Vibe"
    0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0,  // tempo 600000 µs = 100 BPM
    0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,  // 3/4
    0x00, 0xC0, 0x0B,  // program 11 (Vibraphone)
    0x00, 0x90, 0x3C, 0x64,  // note on C, velocity 100, at 0
    0x60, 0x3C, 0x00,  // running status: velocity 0 = note off, 96 ticks later
    0x00, 0x40, 0x50,  // running status: note on E, velocity 80
    0x30, 0x80, 0x40, 0x00,  // note off E, 48 ticks later
    0x00, 0xFF, 0x2F, 0x00,  // end of track
  ]

  @Test func readsAHandBuiltFormatZeroFile() throws {
    let contents = try StandardMIDIFile.read(Data(formatZeroFile))

    #expect(contents.tempoMap.tempo(at: .zero) == 100)
    #expect(contents.tempoMap.timeSignature(atBarIndex: 0) == TimeSignature(beatsPerBar: 3, beatUnit: 4))
    #expect(contents.tracks.count == 1)

    let track = try #require(contents.tracks.first)
    #expect(track.name == "Vibe")
    #expect(track.kind == .softwareInstrument)
    #expect(track.channel.instrument == .generalMIDI(program: 11))

    let region = try #require(track.regions.first)
    #expect(region.start == .zero)
    #expect(region.length == Tick(2880))  // one bar of 3/4
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    // 96 file ticks = one quarter note = 960 Ongaku ticks.
    #expect(sequence.notes.map(\.pitch) == [60, 64])
    #expect(sequence.notes.map(\.start) == [.zero, Tick(960)])
    #expect(sequence.notes.map(\.length) == [Tick(960), Tick(480)])
    #expect(sequence.notes.map(\.velocity) == [100, 80])
  }

  /// Controllers, pitch bend and aftertouch, with running status, before and among notes.
  private let controllersFile: [UInt8] = [
    0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,  // MThd, format 0, 1 track, 96 PPQ
    0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 31,  // MTrk, 31 bytes
    0x00, 0xB1, 0x07, 0x64,  // channel 2 volume 100, at 0
    0x00, 0x0A, 0x20,  // running status: pan 32
    0x83, 0x00, 0x91, 0x3C, 0x50,  // 384 ticks (bar 2): note on C, channel 2
    0x30, 0xE1, 0x00, 0x60,  // 48 ticks later: pitch bend +4096
    0x00, 0xD1, 0x40,  // channel pressure 64
    0x00, 0xA1, 0x3C, 0x22,  // poly pressure on C: 34
    0x30, 0x81, 0x3C, 0x00,  // note off, 48 ticks later
    0x00, 0xFF, 0x2F, 0x00,  // end of track
  ]

  @Test func readsControllersPitchBendAndAftertouch() throws {
    let contents = try StandardMIDIFile.read(Data(controllersFile))
    let region = try #require(contents.tracks.first?.regions.first)
    // The volume and pan at the very start keep the region starting at bar 1.
    #expect(region.start == .zero)
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    #expect(sequence.notes.map(\.start) == [Tick(3840)])
    #expect(sequence.controls.map(\.kind) == [.volume, .pan, .pitchBend, .channelPressure, .polyPressure(pitch: 60)])
    #expect(sequence.controls.map(\.value) == [100, 32, 4096, 64, 34])
    #expect(sequence.controls.map(\.position) == [.zero, .zero, Tick(4320), Tick(4320), Tick(4320)])
    #expect(sequence.controls.allSatisfy { $0.channel == 1 })
  }

  @Test func controllersRoundTrip() throws {
    let controls = [
      MIDIControlEvent(kind: .sustain, position: Tick(0), value: 127),
      MIDIControlEvent(kind: .pitchBend, position: Tick(480), value: -2000),
      MIDIControlEvent(kind: .sustain, position: Tick(1920), value: 0),
      MIDIControlEvent(kind: .polyPressure(pitch: 60), position: Tick(960), value: 90),
    ]
    let note = MIDINote(pitch: 60, start: .zero, length: Tick(1920))
    let keys = Track(
      name: "Keys", kind: .softwareInstrument,
      regions: [Region(name: "Keys", start: Tick(3840), length: Tick(3840), content: .midi(MIDISequence(notes: [note], controls: controls)))])
    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(Project(tracks: [keys])))
    let region = try #require(contents.tracks.first?.regions.first)
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    let read = sequence.controls.map { ($0.kind, region.start + $0.position, $0.value) }
    let written = MIDISequence(controls: controls).controls.map { ($0.kind, Tick(3840) + $0.position, $0.value) }
    #expect(read.map(\.0) == written.map(\.0))
    #expect(read.map(\.1) == written.map(\.1))
    #expect(read.map(\.2) == written.map(\.2))
  }

  @Test func roundTripsAProject() throws {
    var tempoMap = TempoMap(bpm: 132)
    try tempoMap.setTempo(90, at: Tick(3840 * 4))
    try tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 6, beatUnit: 8), atBarIndex: 2)

    let bass = Track(
      name: "Bass", kind: .softwareInstrument, channel: ChannelStrip(instrument: .generalMIDI(program: 33)),
      regions: [
        Region(
          name: "Bass", start: Tick(3840), length: Tick(3840),
          content: .midi(MIDISequence(notes: [
            MIDINote(pitch: 36, velocity: 110, start: .zero, length: Tick(480)),
            MIDINote(pitch: 43, velocity: 70, start: Tick(1920), length: Tick(960)),
          ])))
      ])
    let drums = Track(
      name: "Drums", kind: .softwareInstrument, channel: ChannelStrip(instrument: .generalMIDIPercussion(kit: 0)),
      regions: [
        Region(
          name: "Beat", start: .zero, length: Tick(3840),
          content: .midi(MIDISequence(notes: [MIDINote(pitch: 36, channel: 9, start: .zero, length: Tick(240))])))
      ])
    let project = Project(tempoMap: tempoMap, tracks: [bass, drums, Track(name: "Audio 1", kind: .audio)])

    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(project))

    #expect(contents.tempoMap == tempoMap)
    #expect(contents.tracks.map(\.name) == ["Bass", "Drums"])
    #expect(contents.tracks.map(\.channel.instrument) == [.generalMIDI(program: 33), .generalMIDIPercussion(kit: 0)])

    let importedBass = try #require(contents.tracks.first?.regions.first)
    #expect(importedBass.start == Tick(3840))
    guard case .midi(let sequence) = importedBass.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    #expect(sequence.notes.map(\.pitch) == [36, 43])
    #expect(sequence.notes.map(\.start) == [.zero, Tick(1920)])
    #expect(sequence.notes.map(\.length) == [Tick(480), Tick(960)])
    #expect(sequence.notes.map(\.velocity) == [110, 70])
  }

  @Test func exportCutsNotesAtTheRegionEndAndSkipsMutedRegions() throws {
    let region = Region(
      name: "Riff", start: .zero, length: Tick(960),
      content: .midi(MIDISequence(notes: [MIDINote(pitch: 60, start: .zero, length: Tick(3840))])))
    var muted = region
    muted.id = UUID()
    muted.start = Tick(3840)
    muted.isMuted = true
    let project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region, muted])])

    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(project))
    guard case .midi(let sequence) = contents.tracks.first?.regions.first?.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    #expect(sequence.notes.count == 1)
    #expect(sequence.notes.first?.length == Tick(960))
  }

  @Test func exportIncludesLoopRepeatsUpToTheProjectEnd() throws {
    let bar = Tick(3840)
    var region = Region(
      name: "Riff", start: .zero, length: bar,
      content: .midi(MIDISequence(notes: [MIDINote(pitch: 60, start: .zero, length: Tick(960))])))
    region.isLooped = true
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    project.endPosition = bar * 4

    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(project))
    guard case .midi(let sequence) = contents.tracks.first?.regions.first?.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    #expect(sequence.notes.map(\.start) == [.zero, bar, bar * 2, bar * 3], "The region and its three repeats")
  }

  @Test func rejectsFilesItCantRead() {
    #expect(throws: StandardMIDIFile.ReadError.notAMIDIFile) {
      try StandardMIDIFile.read(Data("RIFF....".utf8))
    }
    #expect(throws: StandardMIDIFile.ReadError.truncated) {
      try StandardMIDIFile.read(Data(formatZeroFile.prefix(30)))
    }
    var smpte = formatZeroFile
    smpte[12] = 0xE7  // negative SMPTE format in the division field
    #expect(throws: StandardMIDIFile.ReadError.unsupportedTiming) {
      try StandardMIDIFile.read(Data(smpte))
    }
  }

  @Test func importTracksAddsTracksTempoAndLength() throws {
    var project = Project.newDefault()
    project.endPosition = Tick(3840 * 4)
    let contents = try StandardMIDIFile.read(Data(formatZeroFile))
    var longer = contents.tracks[0]
    longer.regions[0].start = Tick(3840 * 10)

    try ImportTracks([longer], tempoMap: contents.tempoMap).apply(to: &project)

    #expect(project.tracks.map(\.name) == ["Inst 1", "Vibe"])
    #expect(project.tempoMap.tempo(at: .zero) == 100)
    #expect(project.endPosition > longer.regions[0].end)
  }

  @Test func quantizeSnapsStartsToTheGridFromEachBarLine() throws {
    // 7/8: bars are 3360 ticks, so bar 2 starts at 3360, which isn't a multiple of 960.
    var tempoMap = TempoMap()
    try tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 7, beatUnit: 8), atBarIndex: 0)
    let early = MIDINote(pitch: 60, start: Tick(3360 + 470), length: Tick(100))
    let late = MIDINote(pitch: 62, start: Tick(3360 + 1010), length: Tick(100))
    let region = Region(name: "Odd", start: .zero, length: Tick(6720), content: .midi(MIDISequence(notes: [early, late])))
    var project = Project(tempoMap: tempoMap, tracks: [Track(name: "Inst 1", kind: .softwareInstrument, regions: [region])])

    try QuantizeNotes(in: region.id, grid: Tick(480)).apply(to: &project)

    guard case .midi(let sequence) = project.region(withID: region.id)?.content else {
      Issue.record("Expected a MIDI region")
      return
    }
    #expect(sequence.notes.map(\.start) == [Tick(3360 + 480), Tick(3360 + 960)])
    #expect(sequence.notes.map(\.length) == [Tick(100), Tick(100)])
  }

  @Test(arguments: [(0, [0x00]), (0x7F, [0x7F]), (0x80, [0x81, 0x00]), (0x0FFF_FFFF, [0xFF, 0xFF, 0xFF, 0x7F])])
  func variableLengthQuantities(value: Int, expected: [UInt8]) {
    #expect(StandardMIDIFile.variableLength(value) == expected)
  }
}
