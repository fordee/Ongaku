//
//  LoopImportTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// Loops from sound libraries follow the song: tagged audio loops are stretched to its
/// tempo and moved to its key, and MIDI loops come in as notes.
@MainActor
struct LoopImportTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "LoopImportTests-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
  }

  private func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
  }

  /// A 16-bit stereo WAV of silence with ACID tags: `beats` at `tempo`, root note C.
  private func acidLoop(seconds: Double, tempo: Float, beats: Int) throws -> URL {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      Array(type.utf8) + littleEndian(UInt64(body.count), 4) + body
    }
    let rate = 48000
    let fmt = littleEndian(1, 2) + littleEndian(2, 2) + littleEndian(UInt64(rate), 4) + littleEndian(UInt64(rate * 4), 4)
      + littleEndian(4, 2) + littleEndian(16, 2)
    let acid = littleEndian(2, 4) + littleEndian(60, 2) + littleEndian(0x8000, 2) + littleEndian(0, 4) + littleEndian(UInt64(beats), 4)
      + littleEndian(4, 2) + littleEndian(4, 2) + littleEndian(UInt64(tempo.bitPattern), 4)
    let body = Array("WAVE".utf8) + chunk("fmt ", fmt) + chunk("acid", acid)
      + chunk("data", [UInt8](repeating: 0, count: Int(seconds * Double(rate)) * 4))
    let url = folder.appending(path: "Groove 120.wav")
    try Data(Array("RIFF".utf8) + littleEndian(UInt64(body.count), 4) + body).write(to: url)
    return url
  }

  /// An Apple Loops CAF of a C major keyboard part with a MIDI file of one note (C3, a beat
  /// long).
  private func midiLoop() throws -> URL {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      Array(type.utf8) + bigEndian(UInt64(body.count), 8) + body
    }
    let events: [UInt8] = [0x00, 0x90, 60, 100, 0x83, 0x60, 0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
    let midi = Array("MThd".utf8) + bigEndian(6, 4) + bigEndian(0, 2) + bigEndian(1, 2) + bigEndian(480, 2)
      + Array("MTrk".utf8) + bigEndian(UInt64(events.count), 4) + events
    let pairs: [(String, String)] = [("beat count", "4"), ("key signature", "C"), ("key type", "major"), ("category", "Keyboards")]
    let tags: [UInt8] = pairs.flatMap { key, value -> [UInt8] in Array(key.utf8) + [0] + Array(value.utf8) + [0] }
    let desc = bigEndian(44100.0.bitPattern, 8) + Array("lpcm".utf8) + bigEndian(0, 4) + bigEndian(4, 4) + bigEndian(1, 4)
      + bigEndian(2, 4) + bigEndian(16, 4)
    let bytes = Array("caff".utf8) + bigEndian(1, 2) + bigEndian(0, 2) + chunk("desc", desc)
      + chunk("data", bigEndian(0, 4) + [UInt8](repeating: 0, count: 88_200 * 4))
      + chunk("uuid", [0x29, 0x81, 0x92, 0x73, 0xB5, 0xBF, 0x4A, 0xEF, 0xB7, 0x8D, 0x62, 0xD1, 0xEF, 0x90, 0xBB, 0x2C] + bigEndian(4, 4) + tags)
      + chunk("midi", midi)
    let url = folder.appending(path: "Morning Keys.caf")
    try Data(bytes).write(to: url)
    return url
  }

  @Test func taggedLoopsFollowTheSongsTempoAndKey() async throws {
    var project = Project(tracks: [])
    try project.tempoMap.setTempo(100, at: .zero)
    project.keySignature = KeySignature(tonic: 9, mode: .minor)
    let model = ProjectWindowModel(document: OngakuDocument(project: project))

    // Four beats at 120 BPM: 2 seconds, with C as its root.
    await model.importAudio([try acidLoop(seconds: 2, tempo: 120, beats: 4)], at: .zero, onTrack: nil)

    let track = try #require(model.project.tracks.first)
    #expect(track.kind == .audio)
    let region = try #require(track.regions.first)
    #expect(region.length == .quarterNotes(4), "Four beats long, at the song's tempo")
    guard case .audio(let audio) = region.content else { Issue.record("Not audio"); return }
    // At 100 BPM four beats take 2.4 s, so the 2 s recording plays at 2/2.4 speed.
    #expect(abs(audio.stretch - 2 / 2.4) < 0.001)
    // C into A minor: down 3 semitones (nearer than up 9).
    #expect(region.transpose == -3)
  }

  @Test func untaggedAudioIsLeftAsRecorded() async throws {
    let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [])))
    // A one-second file with no tags and nothing in its name.
    let url = folder.appending(path: "Take 1.wav")
    var file = try acidLoop(seconds: 1, tempo: 120, beats: 2)
    let data = try Data(contentsOf: file)
    // Blank the ACID chunk's tag so it's an unknown chunk.
    var bytes = [UInt8](data)
    if let index = bytes.indices.first(where: { bytes[$0..<min($0 + 4, bytes.count)].elementsEqual("acid".utf8) }) {
      bytes.replaceSubrange(index..<(index + 4), with: Array("junk".utf8))
    }
    try Data(bytes).write(to: url)
    file = url
    await model.importAudio([file], at: .zero, onTrack: nil)
    let region = try #require(model.project.tracks.first?.regions.first)
    guard case .audio(let audio) = region.content else { Issue.record("Not audio"); return }
    #expect(audio.stretch == 1)
    #expect(region.transpose == 0)
  }

  @Test func midiLoopsBecomeNotesOnAnInstrumentTrack() async throws {
    var project = Project(tracks: [])
    project.keySignature = KeySignature(tonic: 4, mode: .minor)
    let model = ProjectWindowModel(document: OngakuDocument(project: project))

    await model.importAudio([try midiLoop()], at: .quarterNotes(4), onTrack: nil)

    let track = try #require(model.project.tracks.first)
    #expect(track.kind == .softwareInstrument)
    #expect(track.channel.instrument == .generalMIDI(program: 4), "A keyboard loop gets an electric piano")
    let region = try #require(track.regions.first)
    #expect(region.start == .quarterNotes(4))
    #expect(region.length == .quarterNotes(4))
    guard case .midi(let sequence) = region.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [60])
    #expect(sequence.notes.first?.length == .quarterNotes(1))
    // C major into E minor goes to its relative major, G: down 5.
    #expect(region.transpose == -5)
    #expect(model.project.audioFiles.isEmpty, "No audio is copied for a MIDI loop")
  }

  @Test func midiLoopsDroppedOnAudioTracksComeInAsAudio() async throws {
    let audioTrack = Track(name: "Audio 1", kind: .audio)
    let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [audioTrack])))
    await model.importAudio([try midiLoop()], at: .zero, onTrack: audioTrack.id)
    #expect(model.project.tracks.count == 1)
    let region = try #require(model.project.tracks[0].regions.first)
    guard case .audio = region.content else { Issue.record("Not audio"); return }
    #expect(region.length == .quarterNotes(4))
  }
}

/// Library folders: remembered, indexed in the background, and loaded from the saved index.
@MainActor
struct SoundLibrariesTests {
  @Test func foldersAreIndexedAndRemembered() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SoundLibrariesTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appending(path: "My Pack/Kicks")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try Data("RIFF".utf8).write(to: pack.appending(path: "Kick 01.wav"))
    try Data("<region>".utf8).write(to: root.appending(path: "My Pack/Bells.sfz"))
    let suite = "SoundLibrariesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let indexes = root.appending(path: "Indexes")

    let libraries = SoundLibraries(defaults: defaults, indexDirectory: indexes)
    let id = try libraries.add(root.appending(path: "My Pack"))
    try await waitUntilReady(libraries, id)
    let library = try #require(libraries.library(withID: id))
    #expect(library.name == "My Pack")
    #expect(library.items.map(\.path) == ["Bells.sfz", "Kicks/Kick 01.wav"])
    #expect(library.count(of: .oneShot) == 1)
    #expect(library.count(of: .instrument) == 1)
    #expect(library.items.last?.category == .drums)

    // A second app launch finds the folder from its bookmark and its saved index.
    try await Task.sleep(for: .milliseconds(300))
    let relaunched = SoundLibraries(defaults: defaults, indexDirectory: indexes)
    #expect(relaunched.libraries.map(\.name) == ["My Pack"])
    #expect(relaunched.library(withID: id)?.items.count == 2, "Loaded before rescanning")
    relaunched.remove(id)
    #expect(relaunched.libraries.isEmpty)
    #expect(SoundLibraries(defaults: defaults, indexDirectory: indexes).libraries.isEmpty)
  }

  private func waitUntilReady(_ libraries: SoundLibraries, _ id: UUID) async throws {
    for _ in 0..<100 {
      if libraries.library(withID: id)?.status == .ready, libraries.library(withID: id)?.scanned != nil { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("The library wasn't indexed in time")
  }

  /// An EXS instrument with one sample chunk, pointing at `folder`/`file`.
  private func exs(folder: String, file: String) -> Data {
    func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }
    func chunk(type: UInt64, body: [UInt8]) -> [UInt8] {
      littleEndian(0x0000_0101 | type << 24, 4) + littleEndian(UInt64(body.count), 4) + littleEndian(0, 8) + Array("TBOS".utf8)
        + [UInt8](repeating: 0, count: 64) + body
    }
    func field(_ text: String) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: 256 - text.utf8.count) }
    return Data(chunk(type: 0, body: [UInt8](repeating: 0, count: 40)) + chunk(type: 3, body: [UInt8](repeating: 0, count: 80) + field(folder) + field(file)))
  }

  @Test func movedEXSSamplesAreFoundInTheLibraries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SoundLibrariesTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "Keys Library")
    try FileManager.default.createDirectory(at: library.appending(path: "Instruments"), withIntermediateDirectories: true)
    // Two files of the same name: the one in the folder the instrument named is the one.
    for folder in ["Samples/Rhodes", "Samples/Other"] {
      try FileManager.default.createDirectory(at: library.appending(path: folder), withIntermediateDirectories: true)
      try Data("RIFF".utf8).write(to: library.appending(path: "\(folder)/Rhodes C3.wav"))
    }
    try exs(folder: "/Library/Application Support/Old/Samples/Rhodes", file: "Rhodes C3.wav")
      .write(to: library.appending(path: "Instruments/Rhodes.exs"))
    let suite = "SoundLibrariesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    try await waitUntilReady(libraries, id)

    let instrument = SamplerInstrument(libraryID: id, libraryName: "Keys Library", path: "Instruments/Rhodes.exs")
    let url = try await libraries.url(for: instrument)
    #expect(url.lastPathComponent == "Rhodes.exs")
    #expect(url != library.appending(path: "Instruments/Rhodes.exs"), "A relocated copy")
    let relocated = try #require(EXSInstrument(data: Data(contentsOf: url)))
    let expected = library.appending(path: "Samples/Rhodes").standardizedFileURL.path(percentEncoded: false)
    #expect(relocated.samples.first?.folder.hasSuffix("Keys Library/Samples/Rhodes") == true, "\(relocated.samples.first?.folder ?? "") vs \(expected)")

    // The Library lists it under its library and folder.
    let catalog = LibraryCatalog(audioUnits: [], libraries: libraries.libraries)
    // The Library lists it in its library's folder, as on disk.
    let libraryFolder = try #require(catalog.categories.first { $0.name == "Keys Library" })
    #expect(libraryFolder.children.map(\.name) == ["Instruments"], "Only folders with instruments")
    let category = try #require(libraryFolder.children.first)
    #expect(category.items.map(\.name) == ["Rhodes"])
    #expect(catalog.categoryPath(containing: .sampler(instrument)) == [libraryFolder.id, category.id])
    #expect(catalog.filtered(by: "rhodes").first { $0.id == libraryFolder.id }?.children.first?.items.map(\.name) == ["Rhodes"])
    #expect(category.items.first?.isLoaded(on: .sampler(instrument)) == true)

    // A song from another Mac, whose library has another ID but the same name, finds it.
    let elsewhere = SamplerInstrument(libraryID: UUID(), libraryName: "Keys Library", path: "Instruments/Rhodes.exs")
    #expect(libraries.library(for: elsewhere)?.id == id)
    await #expect(throws: (any Error).self) {
      try await libraries.url(for: SamplerInstrument(libraryID: nil, libraryName: "Gone", path: "Nowhere.exs"))
    }
  }

}

/// Impulse responses from the libraries reach the Convolution Reverb through its settings,
/// as its own window can't see the libraries.
@MainActor
struct ImpulseResponseTests {
  @Test func libraryImpulseResponsesLoadIntoTheConvolutionReverb() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "IR-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A second of decaying stereo noise at 48 kHz, as a Space Designer file (AIFF inside).
    let url = folder.appending(path: "Small Room.SDIR")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    do {
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
      ]
      let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
      buffer.frameLength = 48000
      for channel in 0..<2 {
        for frame in 0..<48000 {
          buffer.floatChannelData![channel][frame] = Float.random(in: -0.5...0.5) * exp(-Float(frame) / 6000)
        }
      }
      try file.write(from: buffer)
    }
    let state = try ProjectWindowModel.impulseState(contentsOf: url)
    #expect(state["name"] as? String == "Small Room")
    #expect(state["channels"] as? Int == 2)
    #expect((state["audio"] as? Data)?.count == 48000 * 2 * 4)

    // On a track's Convolution Reverb: the song keeps it, and the running plug-in uses it.
    let reverb = OngakuEffect.convolutionReverb.makeReference()
    var track = Track(name: "Vocal", kind: .audio)
    track.channel.inserts = [reverb]
    let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track])))
    for _ in 0..<100 where model.engine.isLoadingInsert(reverb.id, onTrack: track.id) {
      try await Task.sleep(for: .milliseconds(50))
    }
    try model.useImpulseResponse(at: url, forInsert: reverb.id, on: track.id)
    // The window's view passes the change to the engine; here there's no window.
    model.projectDidChange()
    let saved = try #require(model.project.tracks[0].channel.inserts[0].state)
    let savedState = try #require(try PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any])
    #expect((savedState[ProjectWindowModel.impulseStateKey] as? [String: Any])?["name"] as? String == "Small Room")

    var live: [String: Any]?
    for _ in 0..<40 {
      if let data = model.engine.insertState(reverb.id, onTrack: track.id),
        let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        state[ProjectWindowModel.impulseStateKey] != nil
      {
        live = state
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect((live?[ProjectWindowModel.impulseStateKey] as? [String: Any])?["name"] as? String == "Small Room",
      "The plug-in itself reports the impulse response")
  }
}

/// Agents add library loops through the window, the same way dragging one in does.
@MainActor
struct AgentLibraryTests {
  @Test func agentsAddLoopsThatFollowTheSong() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "AgentLibrary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "Agent Loops")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    // Four beats at 120 BPM, as an ACID-tagged WAV (C root).
    func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) } }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { Array(type.utf8) + littleEndian(UInt64(body.count), 4) + body }
    let fmt = littleEndian(1, 2) + littleEndian(2, 2) + littleEndian(48000, 4) + littleEndian(192_000, 4) + littleEndian(4, 2) + littleEndian(16, 2)
    let acid = littleEndian(2, 4) + littleEndian(60, 2) + littleEndian(0x8000, 2) + littleEndian(0, 4) + littleEndian(4, 4)
      + littleEndian(4, 2) + littleEndian(4, 2) + littleEndian(UInt64(Float(120).bitPattern), 4)
    let body = Array("WAVE".utf8) + chunk("fmt ", fmt) + chunk("acid", acid) + chunk("data", [UInt8](repeating: 0, count: 96_000 * 4))
    try Data(Array("RIFF".utf8) + littleEndian(UInt64(body.count), 4) + body).write(to: library.appending(path: "Groove.wav"))

    let suite = "AgentLibrary-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    for _ in 0..<100 where libraries.library(withID: id)?.scanned == nil {
      try await Task.sleep(for: .milliseconds(50))
    }

    var project = Project(tracks: [])
    try project.tempoMap.setTempo(100, at: .zero)
    let model = ProjectWindowModel(document: OngakuDocument(project: project))
    model.soundLibraryStore = libraries
    let found = try await AgentToolbox.call("find_loops", arguments: [:], in: model)
    let sound = try #require(found["sounds"]?.arrayValue?.first?["sound"])
    #expect(sound == "Agent Loops/Groove.wav")
    let added = try await AgentToolbox.call("add_loop", arguments: ["sound": sound, "at": "3"], in: model)
    let region = try #require(added["regions"]?.arrayValue?.first)
    #expect(region["start"] == "3:1")
    #expect(region["track"] == "Groove")
    let placed = try #require(model.project.tracks.first?.regions.first)
    #expect(placed.length == .quarterNotes(4), "Four beats at the song's 100 BPM")
    guard case .audio(let audio) = placed.content else { Issue.record("Not audio"); return }
    #expect(abs(audio.stretch - 2 / 2.4) < 0.001)
    #expect(model.undoManager?.undoActionName == "Agent: Add Groove" || model.undoManager == nil)
  }
}
