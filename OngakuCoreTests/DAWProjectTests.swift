//
//  DAWProjectTests.swift
//  OngakuCoreTests
//

import Compression
import Foundation
import Testing
@testable import OngakuCore

/// DAWproject interchange: the ZIP container, a song exported and read back, and a project
/// written the way other apps write them.
struct DAWProjectTests {
  private let beat = Tick(960)

  // MARK: ZIP

  @Test func zipArchivesRoundTripAndReadDeflatedEntries() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    let entries = [
      ZipArchive.Entry(path: "project.xml", data: Data("<Project/>".utf8)),
      ZipArchive.Entry(path: "audio/ü.wav", data: Data((0..<5000).map { UInt8($0 % 251) })),
    ]
    try ZipArchive.write(entries, to: url)
    let read = try ZipArchive.read(Data(contentsOf: url))
    #expect(read.map(\.path) == entries.map(\.path))
    #expect(read.map(\.data) == entries.map(\.data))
    // The checksum is the standard CRC-32.
    #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)

    // Deflated, as most apps write: inflated back to the original.
    let text = Data(String(repeating: "Ongaku DAWproject ", count: 200).utf8)
    var compressed = Data(count: text.count + 64)
    let size = compressed.withUnsafeMutableBytes { destination in
      text.withUnsafeBytes { source in
        compression_encode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, text.count + 64, source.bindMemory(to: UInt8.self).baseAddress!,
          text.count, nil, COMPRESSION_ZLIB)
      }
    }
    #expect(try ZipArchive.inflate(compressed.prefix(size), size: text.count, name: "x") == text)
    #expect(throws: ZipArchive.ZipError.self) { try ZipArchive.read(Data("not a zip at all, sorry".utf8)) }
  }

  // MARK: Round trip

  private func song() -> Project {
    var project = Project()
    try? project.tempoMap.setTempo(96)
    try? project.tempoMap.setTempo(120, at: beat * 16)
    project.tempoMap.setRamp(true, at: beat * 16)
    try? project.tempoMap.setTempo(110, at: beat * 32)
    try? project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 4)
    project.markers = [Marker(name: "Bridge", position: beat * 8)]
    project.masterVolume = -3

    let reverb = Track(name: "Reverb", kind: .aux)
    var keys = Track(name: "Keys", kind: .softwareInstrument, color: .purple)
    keys.channel.instrument = .audioUnit(OngakuInstrument.retroSynth.makeReference())
    keys.channel.volume = -6
    keys.channel.pan = -0.5
    keys.channel.isMuted = true
    keys.channel.sends = [Send(destinationTrackID: reverb.id, level: -12)]
    var compressor = BuiltInEffect.compressor.makeReference()
    compressor.state = Data("state".utf8)
    compressor.isBypassed = true
    keys.channel.inserts = [compressor]
    let notes = [MIDINote(pitch: 60, velocity: 100, start: .zero, length: beat), MIDINote(pitch: 67, velocity: 64, start: beat, length: beat * 2)]
    var looped = Region(name: "Riff", start: beat * 4, length: beat * 4, content: .midi(MIDISequence(notes: notes)))
    looped.isLooped = true
    looped.loopedLength = beat * 12
    keys.regions = [looped]
    keys.automation = [AutomationLane(parameter: .volume, points: [AutomationPoint(position: .zero, value: -6), AutomationPoint(position: beat * 8, value: 0)])]

    let file = AudioFileReference(fileName: "Vox.wav", sampleRate: 48_000, channelCount: 1, frameCount: 96_000)
    project.audioFiles = [file]
    var vocals = Track(name: "Vocals", kind: .audio)
    vocals.regions = [Region(name: "Take 1", start: beat * 2, length: beat * 2, content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 24_000, fadeIn: 0.1)))]

    var stack = Track(name: "Band", kind: .aux)
    stack.isSummingStack = true
    var bass = Track(name: "Bass", kind: .softwareInstrument)
    bass.channel.instrument = .generalMIDI(program: 33)
    bass.stackID = stack.id
    project.tracks = [keys, vocals, stack, bass, reverb]
    return project
  }

  private func roundTrip(_ project: Project) throws -> (DAWProject.Import, DAWProject.Export) {
    let export = DAWProject.export(project, title: "Demo", audioData: { _ in Data(repeating: 1, count: 100) }, pluginState: { $0.state })
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).dawproject")
    defer { try? FileManager.default.removeItem(at: url) }
    try ZipArchive.write(export.entries, to: url)
    return (try DAWProject.read(ZipArchive.read(Data(contentsOf: url))), export)
  }

  @Test func aSongComesBackAsItWent() throws {
    let original = song()
    let (imported, export) = try roundTrip(original)
    let project = imported.project
    #expect(imported.title == "Demo")
    #expect(export.warnings.contains { $0.contains("General MIDI") }, "The GM bass is named as not carrying over")

    // Tempo, ramps, meters, markers.
    #expect(project.tempoMap.tempoChanges.map(\.bpm) == [96, 120, 110])
    #expect(project.tempoMap.tempoChanges.map(\.rampsToNext) == [false, true, false])
    #expect(project.tempoMap.timeSignature(atBarIndex: 4) == TimeSignature(beatsPerBar: 3, beatUnit: 4))
    #expect(project.markers.map(\.name) == ["Bridge"])
    #expect(abs(project.masterVolume - -3) < 0.01)

    // Tracks, in order, with their kinds and the stack.
    #expect(project.tracks.map(\.name) == ["Keys", "Vocals", "Band", "Bass", "Reverb"])
    #expect(project.tracks.map(\.kind) == [.softwareInstrument, .audio, .aux, .softwareInstrument, .aux])
    let stack = try #require(project.tracks.first { $0.name == "Band" })
    #expect(stack.isSummingStack)
    #expect(project.tracks.first { $0.name == "Bass" }?.stackID == stack.id)

    // The mixer.
    let keys = try #require(project.tracks.first { $0.name == "Keys" })
    #expect(abs(keys.channel.volume - -6) < 0.01 && abs(keys.channel.pan - -0.5) < 0.001 && keys.channel.isMuted)
    #expect(keys.color == .purple)
    let reverb = try #require(project.tracks.first { $0.name == "Reverb" })
    #expect(keys.channel.sends.first?.destinationTrackID == reverb.id)
    #expect(abs((keys.channel.sends.first?.level ?? 0) - -12) < 0.01)
    if case .audioUnit(let synth) = keys.channel.instrument {
      #expect(synth.componentSubType == OngakuInstrument.retroSynth.subType)
    } else {
      Issue.record("The Retro Synth is the instrument again")
    }
    #expect(keys.channel.inserts.first?.state == Data("state".utf8))
    #expect(keys.channel.inserts.first?.isBypassed == true)

    // Regions and notes.
    let riff = try #require(keys.regions.first)
    #expect(riff.start == beat * 4 && riff.length == beat * 4 && riff.isLooped && riff.loopedLength == beat * 12)
    guard case .midi(let sequence) = riff.content else { Issue.record("MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [60, 67])
    #expect(sequence.notes.map(\.velocity) == [100, 64])
    #expect(sequence.notes.map(\.length) == [beat, beat * 2])

    // Audio, with its offset and fade, and a file to copy in.
    let take = try #require(project.tracks.first { $0.name == "Vocals" }?.regions.first)
    guard case .audio(let content) = take.content else { Issue.record("audio"); return }
    #expect(content.fileStartFrame == 24_000 && abs(content.fadeIn - 0.1) < 0.0001)
    #expect(imported.audioFiles.count == 1 && imported.audioFiles[0].reference.id == content.fileID)

    // Automation.
    #expect(keys.automation.first?.points.map(\.position) == [.zero, beat * 8])
    #expect(abs((keys.automation.first?.points.first?.value ?? 0) - -6) < 0.01)
  }

  // MARK: Other apps' files

  @Test func projectsFromOtherAppsAreRead() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Project version="1.0">
        <Application name="Other DAW" version="5.0"/>
        <Transport><Tempo unit="bpm" value="140.0" id="t"/><TimeSignature numerator="6" denominator="8"/></Transport>
        <Structure>
          <Track contentType="tracks" id="g" name="Drums Group" color="#ff0000">
            <Channel role="submix" id="gc" destination="m"><Volume unit="linear" value="1.0" id="gv"/></Channel>
            <Track contentType="audio" id="k" name="Kick">
              <Channel role="regular" id="kc" destination="gc">
                <Devices><Vst3Plugin deviceName="Pro-Q 3" name="Pro-Q 3" deviceRole="audioFX"/></Devices>
                <Volume unit="linear" value="0.5" id="kv"/><Pan unit="normalized" value="0.75" id="kp"/>
              </Channel>
            </Track>
          </Track>
          <Track contentType="notes" id="s" name="Lead"><Channel role="regular" id="sc" destination="m"/></Track>
          <Track contentType="audio notes" id="mt" name="Master"><Channel role="master" id="m"><Volume unit="linear" value="0.5" id="mv"/></Channel></Track>
        </Structure>
        <Arrangement>
          <Lanes timeUnit="beats">
            <Lanes track="s">
              <Clips><Clip time="4.0" duration="4.0" playStart="0.0"><Notes><Note time="0.5" duration="0.5" key="72" vel="0.5"/></Notes></Clip></Clips>
            </Lanes>
            <Lanes track="k">
              <Clips><Clip time="0.0" duration="2.0" contentTimeUnit="beats" playStart="0.0">
                <Warps timeUnit="beats" contentTimeUnit="seconds">
                  <Audio sampleRate="44100" channels="2" duration="1.0"><File path="audio/kick.wav"/></Audio>
                  <Warp time="0.0" contentTime="0.0"/><Warp time="2.0" contentTime="1.0"/>
                </Warps>
              </Clip></Clips>
              <Points unit="linear"><Target parameter="kv"/><RealPoint time="0.0" value="1.0"/><RealPoint time="2.0" value="0.0"/></Points>
            </Lanes>
          </Lanes>
        </Arrangement>
      </Project>
      """
    let imported = try DAWProject.read([
      ZipArchive.Entry(path: "project.xml", data: Data(xml.utf8)), ZipArchive.Entry(path: "audio/kick.wav", data: Data([1, 2, 3])),
    ])
    let project = imported.project
    #expect(project.tempoMap.tempoChanges.first?.bpm == 140)
    #expect(project.tempoMap.timeSignature(atBarIndex: 0) == TimeSignature(beatsPerBar: 6, beatUnit: 8))
    #expect(project.tracks.map(\.name) == ["Drums Group", "Kick", "Lead"])
    #expect(project.tracks[0].isSummingStack && project.tracks[1].stackID == project.tracks[0].id)
    #expect(project.tracks[0].color == .red)
    #expect(abs(project.tracks[1].channel.volume - -6.02) < 0.01 && abs(project.tracks[1].channel.pan - 0.5) < 0.001)
    #expect(abs(project.masterVolume - -6.02) < 0.01)
    #expect(project.tracks[1].channel.output == .stereoOut, "Its group already gathers it")
    #expect(project.tracks[2].regions.first?.start == beat * 4)
    guard case .midi(let sequence) = project.tracks[2].regions.first?.content else { Issue.record("notes"); return }
    #expect(sequence.notes.first?.start == Tick(480) && sequence.notes.first?.velocity == 64)
    #expect(project.tracks[1].regions.count == 1 && imported.audioFiles.first?.data == Data([1, 2, 3]))
    #expect(project.tracks[1].automation.first?.points.count == 2)
    // What didn't carry over is said.
    #expect(imported.warnings.contains { $0.contains("Pro-Q 3") && $0.contains("Vst3") })
    #expect(imported.warnings.contains { $0.contains("warped") })
  }

  @Test func archivesWithoutAProjectAreRefused() {
    #expect(throws: DAWProject.ImportError.self) { try DAWProject.read([ZipArchive.Entry(path: "readme.txt", data: Data())]) }
  }
}
