//
//  ProjectArchiveTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct ProjectArchiveTests {
  @Test func projectRoundTripsThroughJSON() throws {
    var tempoMap = TempoMap(bpm: 98)
    try tempoMap.setTempo(120, at: Tick(3840 * 8))
    try tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 7, beatUnit: 8), atBarIndex: 4)

    let file = AudioFileReference(fileName: "Vocal.wav", sampleRate: 44_100, channelCount: 1, frameCount: 441_000)
    let plugin = PluginReference(
      componentType: 0x6175_6678, componentSubType: 0x7276_6232, componentManufacturer: 0x6170_706C,
      name: "AUReverb2", state: Data([1, 2, 3]))
    let instrument = Track(
      name: "Synth", kind: .softwareInstrument,
      channel: ChannelStrip(volume: -6, pan: 0.25, instrument: .audioUnit(plugin), inserts: [plugin]),
      regions: [
        Region(
          name: "Riff", start: Tick(960), length: Tick(3840),
          content: .midi(MIDISequence(notes: [MIDINote(pitch: 48, velocity: 90, channel: 2, start: .zero, length: Tick(120))])))
      ])
    let audio = Track(
      name: "Vocal", kind: .audio,
      regions: [
        Region(
          name: "Vocal", start: .zero, length: Tick(7680), isMuted: true,
          content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 1_000, gain: -3)))
      ])
    let project = Project(
      sampleRate: 44_100, tempoMap: tempoMap, keySignature: KeySignature(tonic: 9, mode: .minor),
      tracks: [instrument, audio], audioFiles: [file])

    let decoded = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(decoded == project)
  }

  @Test func newerFormatVersionsAreRejected() throws {
    // Saving always writes the current version, so make a newer file by editing the JSON.
    let saved = try ProjectArchive.encode(Project.newDefault())
    var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    object["formatVersion"] = Project.currentFormatVersion + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ProjectArchive.ArchiveError.unsupportedFormatVersion(Project.currentFormatVersion + 1)) {
      try ProjectArchive.decode(data)
    }
  }

  @Test func corruptTempoMapsAreRejected() throws {
    let json = Data(#"{"tempoChanges":[{"position":960,"bpm":120}],"meterChanges":[{"barIndex":0,"signature":{"beatsPerBar":4,"beatUnit":4}}]}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TempoMap.self, from: json)
    }
  }
}
