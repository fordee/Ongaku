//
//  InstrumentLoadingTests.swift
//  OngakuTests
//

import AVFAudio
import AudioToolbox
import Foundation
import OngakuCore
@testable import Ongaku
@testable import OngakuEngine
import Synchronization
import Testing

/// Serialized: the library instrument tests swap the shared instrument resolver.
@MainActor
@Suite(.serialized)
struct InstrumentLoadingTests {
  /// Apple's AUMIDISynth, loaded the same way as a third-party instrument (out of process).
  private let midiSynth = PluginReference(
    componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_MIDISynth,
    componentManufacturer: kAudioUnitManufacturer_Apple, name: "AUMIDISynth")

  func waitForInstrument(_ engine: PlaybackEngine, track trackID: Track.ID) async throws {
    for _ in 0..<100 where engine.isLoadingInstrument(forTrack: trackID) {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test func generalMIDIInstrumentsLoadImmediately() {
    let track = Track(name: "Inst 1", kind: .softwareInstrument)
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }

    #expect(!engine.isLoadingInstrument(forTrack: track.id))
    #expect(engine.withInstrumentAudioUnit(forTrack: track.id) { $0.audioUnitName } != nil)
    #expect(engine.lastError == nil)
  }

  @Test func audioUnitInstrumentsLoadOutOfProcess() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }

    try await waitForInstrument(engine, track: track.id)
    #expect(engine.lastError == nil)
    let componentSubType = engine.withInstrumentAudioUnit(forTrack: track.id) { $0.componentDescription.componentSubType }
    #expect(componentSubType == kAudioUnitSubType_MIDISynth)
  }

  @Test func switchingInstrumentsReplacesTheAudioUnit() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    var project = Project(tracks: [track])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)

    project.tracks[0].channel.instrument = .generalMIDI(program: 40)
    engine.update(project: project)
    let componentSubType = engine.withInstrumentAudioUnit(forTrack: track.id) { $0.componentDescription.componentSubType }
    #expect(componentSubType == kAudioUnitSubType_Sampler)
  }

  @Test func savedPluginSettingsDontReloadThePlugin() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    var project = Project(tracks: [track])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)

    var plugin = midiSynth
    plugin.state = engine.instrumentState(forTrack: track.id)
    #expect(plugin.state != nil)
    project.tracks[0].channel.instrument = .audioUnit(plugin)
    engine.update(project: project)
    #expect(!engine.isLoadingInstrument(forTrack: track.id))
  }

  /// Adding a track restarts the engine, which used to drop the other samplers back to
  /// their default tone: a piano went dull and bass-like.
  @Test func addingATrackKeepsTheOtherTracksSounds() async throws {
    var piano = Track(name: "Inst 1", kind: .softwareInstrument)
    piano.channel.instrument = .generalMIDI(program: 0)
    var project = Project(tracks: [piano])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(300))
    let before = try await brightness(of: engine, playingOn: piano.id)

    project.tracks.append(Track(name: "Inst 2", kind: .softwareInstrument))
    engine.update(project: project)
    try await Task.sleep(for: .milliseconds(300))
    let after = try await brightness(of: engine, playingOn: piano.id)

    #expect(before > 0)
    #expect(abs(after - before) / before < 0.1, "Inst 1 should still sound like a piano (\(before) → \(after) zero crossings/s)")
    #expect(engine.lastError == nil)
  }

  /// A sound library instrument: here an Audio Unit sampler preset made from a 440 Hz tone,
  /// found through the resolver as the app's libraries would find it.
  @Test func libraryInstrumentsPlayInAppleSampler() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LibraryInstrument-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tone = folder.appending(path: "Tone.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
    do {
      let file = try AVAudioFile(forWriting: tone, settings: format.settings)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
      buffer.frameLength = 88_200
      for index in 0..<88_200 { buffer.floatChannelData![0][index] = 0.5 * sin(2 * .pi * 440 * Float(index) / 44100) }
      try file.write(from: buffer)
    }
    let maker = AVAudioUnitSampler()
    try maker.loadAudioFiles(at: [tone])
    let state = try #require(maker.auAudioUnit.fullState)
    let preset = folder.appending(path: "Tone.aupreset")
    try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0).write(to: preset)

    let previous = SamplerInstrumentResolver.resolve
    SamplerInstrumentResolver.resolve = { _ in preset }
    defer { SamplerInstrumentResolver.resolve = previous }
    var track = Track(name: "Tone", kind: .softwareInstrument)
    track.channel.instrument = .sampler(SamplerInstrument(libraryID: nil, libraryName: "Tests", path: "Tone.aupreset"))
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)
    #expect(engine.lastError == nil)
    let componentSubType = engine.withInstrumentAudioUnit(forTrack: track.id) { $0.componentDescription.componentSubType }
    #expect(componentSubType == kAudioUnitSubType_Sampler)
    // Its root note is middle C, so middle C plays the tone: about 880 zero crossings a second.
    let crossings = try await brightness(of: engine, playingOn: track.id)
    #expect(abs(crossings - 880) < 60, "\(crossings) crossings a second")

    // One whose library isn't there says which library to add. (In the same test, as the
    // resolver is shared.)
    SamplerInstrumentResolver.resolve = { throw EngineError.missingSamplerInstrument($0) }
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .sampler(SamplerInstrument(libraryID: nil, libraryName: "Vintage Keys", path: "Rhodes.exs"))
    let missing = PlaybackEngine(project: Project(tracks: [keys])) { _ in nil }
    defer { missing.shutDown() }
    try await waitForInstrument(missing, track: keys.id)
    #expect(missing.lastError?.contains("Vintage Keys") == true, "\(missing.lastError ?? "no error")")
  }

  /// Plays an EXS instrument through the engine, pitches at `notes`.
  private func pitches(of exs: URL, notes: [UInt8]) async throws -> (pitches: [Double], error: String?) {
    let previous = SamplerInstrumentResolver.resolve
    SamplerInstrumentResolver.resolve = { _ in exs }
    defer { SamplerInstrumentResolver.resolve = previous }
    var track = Track(name: "EXS", kind: .softwareInstrument)
    track.channel.instrument = .sampler(SamplerInstrument(libraryID: nil, libraryName: "Tests", path: exs.lastPathComponent))
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)
    if let error = engine.lastError { return ([], error) }
    var result: [Double] = []
    for note in notes { result.append(try await brightness(of: engine, playingOn: track.id, note: note)) }
    return (result, nil)
  }

  /// EXS instruments in the forms libraries use: a file per zone, or one combined file each
  /// zone plays part of; WAV, or big-endian CAF as Logic writes; the newer chunk flags; and
  /// chunks Apple's sampler doesn't use. Middle C's neighbours are measured by zero crossings
  /// (twice the frequency).
  @Test(arguments: [false, true])
  func exsInstrumentsPlayInAppleSampler(bigEndianCAF: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "EXS-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let ext = bigEndianCAF ? "caf" : "wav"
    let path = folder.path(percentEncoded: false)
    try EXSTestFiles.writeTones([(440, 44100)], to: folder.appending(path: "A4.\(ext)"), bigEndian: bigEndianCAF)
    try EXSTestFiles.writeTones([(440, 44100), (880, 44100)], to: folder.appending(path: "Both.\(ext)"), bigEndian: bigEndianCAF)

    let plain = folder.appending(path: "Plain.exs")
    try EXSTestFiles.instrument(
      name: "Plain", zones: [.init(root: 69, keys: 0...127, sampleEnd: 44100)],
      samples: [.init(folder: path, file: "A4.\(ext)", frames: 44100)]
    ).write(to: plain)
    let one = try await pitches(of: plain, notes: [69])
    #expect(one.error == nil, "\(one.error ?? "")")
    #expect(one.pitches.allSatisfy { abs($0 - 880) < 30 }, "\(one.pitches)")

    let combined = folder.appending(path: "Combined.exs")
    try EXSTestFiles.instrument(
      name: "Combined",
      zones: [.init(root: 69, keys: 0...70, sampleEnd: 44100), .init(root: 81, keys: 71...127, sampleStart: 44100, sampleEnd: 88200)],
      samples: [.init(folder: path, file: "Both.\(ext)", frames: 88200)]
    ).write(to: combined)
    let two = try await pitches(of: combined, notes: [69, 81])
    #expect(two.error == nil, "\(two.error ?? "")")
    #expect(two.pitches.count == 2 && abs(two.pitches[0] - 880) < 30 && abs(two.pitches[1] - 1760) < 60, "\(two.pitches)")

    EXSTestFiles.newerFormat = true
    defer { EXSTestFiles.newerFormat = false }
    let plist = try PropertyListSerialization.data(fromPropertyList: ["Layout": ["Zones": 1]], format: .binary, options: 0)
    let newer = folder.appending(path: "Newer.exs")
    try EXSTestFiles.instrument(
      name: "Newer", zones: [.init(root: 69, keys: 0...127, sampleEnd: 44100)],
      samples: [.init(folder: path, file: "A4.\(ext)", frames: 44100)],
      extraChunks: [(4, [UInt8](repeating: 0, count: 64)), (0x0A, [UInt8](plist)), (0x0B, [UInt8](plist))]
    ).write(to: newer)
    let three = try await pitches(of: newer, notes: [69])
    #expect(three.error == nil, "\(three.error ?? "")")
    #expect(three.pitches.allSatisfy { abs($0 - 880) < 30 }, "\(three.pitches)")
  }

  /// An EXS instrument made where its samples were in another folder plays once its library
  /// is added: the libraries find the sample and the engine loads a copy pointing at it.
  @Test func movedEXSInstrumentsPlayFromTheirLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MovedEXS-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "Moved Library")
    try FileManager.default.createDirectory(at: library.appending(path: "Samples/Tone"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library.appending(path: "Instruments"), withIntermediateDirectories: true)
    try EXSTestFiles.writeTones([(440, 44100)], to: library.appending(path: "Samples/Tone/A4.wav"))
    try EXSTestFiles.instrument(
      name: "Tone", zones: [.init(root: 69, keys: 0...127, sampleEnd: 44100)],
      samples: [.init(folder: "/Library/Application Support/Somewhere Else/Samples/Tone", file: "A4.wav", frames: 44100)]
    ).write(to: library.appending(path: "Instruments/Tone.exs"))

    let suite = "MovedEXS-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    for _ in 0..<100 where libraries.library(withID: id)?.scanned == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let instrument = SamplerInstrument(libraryID: id, libraryName: "Moved Library", path: "Instruments/Tone.exs")
    let url = try await libraries.url(for: instrument)
    let result = try await pitches(of: url, notes: [69])
    #expect(result.error == nil, "\(result.error ?? "")")
    #expect(result.pitches.allSatisfy { abs($0 - 880) < 30 }, "\(result.pitches)")
  }

  /// Newer Logic instruments have longer zone chunks, which Apple's sampler won't read; the
  /// libraries' copy of the instrument, with classic zones, plays.
  @Test func newerLogicInstrumentsPlayFromTheirLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "NewerEXS-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "Newer Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try EXSTestFiles.writeTones([(440, 44100), (880, 44100)], to: library.appending(path: "Both.caf"), bigEndian: true)
    let exs = library.appending(path: "Newer.exs")
    try EXSTestFiles.instrument(
      name: "Newer",
      zones: [
        .init(root: 69, keys: 0...70, sampleEnd: 44100, size: 148),
        .init(root: 81, keys: 71...127, sampleStart: 44100, sampleEnd: 88200, size: 148),
      ],
      samples: [.init(folder: library.path(percentEncoded: false), file: "Both.caf", frames: 88200, typeCode: "ffac", channels: 1)]
    ).write(to: exs)

    // As it is, Apple's sampler says it's a format it doesn't support.
    let asIs = try await pitches(of: exs, notes: [69])
    #expect(asIs.error?.contains("can’t read") == true, "\(asIs.error ?? "no error")")

    let suite = "NewerEXS-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    for _ in 0..<100 where libraries.library(withID: id)?.scanned == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let url = try await libraries.url(for: SamplerInstrument(libraryID: id, libraryName: "Newer Library", path: "Newer.exs"))
    let fixed = try await pitches(of: url, notes: [69, 81])
    #expect(fixed.error == nil, "\(fixed.error ?? "")")
    #expect(fixed.pitches.count == 2 && abs(fixed.pitches[0] - 880) < 30 && abs(fixed.pitches[1] - 1760) < 60, "\(fixed.pitches)")
  }

  /// An EXS instrument with a group for each velocity layer, as most of Logic's and
  /// GarageBand's are, plays one layer at a time from its library, not all of them at once.
  @Test func exsGroupVelocityLayersPlayOneAtATime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "GroupedEXS-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "Grouped Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try EXSTestFiles.writeTones([(440, 88200)], to: library.appending(path: "Soft.wav"))
    try EXSTestFiles.writeTones([(659.25, 88200)], to: library.appending(path: "Loud.wav"))
    let folder = library.path(percentEncoded: false)
    try EXSTestFiles.instrument(
      name: "Grouped",
      zones: [
        .init(root: 69, keys: 0...127, sampleEnd: 88200, sample: 0, group: 0),
        .init(root: 69, keys: 0...127, sampleEnd: 88200, sample: 1, group: 1),
      ],
      groups: [.init(velocities: 0...80), .init(velocities: 81...127, volume: 6)],
      samples: [.init(folder: folder, file: "Soft.wav", frames: 88200), .init(folder: folder, file: "Loud.wav", frames: 88200)]
    ).write(to: library.appending(path: "Grouped.exs"))

    let suite = "GroupedEXS-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    for _ in 0..<100 where libraries.library(withID: id)?.scanned == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let url = try await libraries.url(for: SamplerInstrument(libraryID: id, libraryName: "Grouped Library", path: "Grouped.exs"))

    let previous = SamplerInstrumentResolver.resolve
    SamplerInstrumentResolver.resolve = { _ in url }
    defer { SamplerInstrumentResolver.resolve = previous }
    var track = Track(name: "Grouped", kind: .softwareInstrument)
    track.channel.instrument = .sampler(SamplerInstrument(libraryID: id, libraryName: "Grouped Library", path: "Grouped.exs"))
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")
    // Zero crossings a second are twice the frequency.
    let soft = try await brightness(of: engine, playingOn: track.id, note: 69, velocity: 60)
    #expect(abs(soft - 880) < 30, "Soft plays only the soft layer: \(soft)")
    try await Task.sleep(for: .seconds(0.5))
    let loud = try await brightness(of: engine, playingOn: track.id, note: 69, velocity: 110)
    #expect(abs(loud - 1318.5) < 40, "Loud plays only the loud layer: \(loud)")
  }

  /// How loud a track's instrument is while a note is held, and a moment after it's let go
  /// (its release).
  private func levels(of engine: PlaybackEngine, playingOn trackID: Track.ID, note: UInt8) async throws -> (held: Float, released: Float) {
    let unit = try #require(engine.instruments[trackID]?.instrument)
    let recording = Recording()
    try unit.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      guard case .float(let samples) = buffer.channelData(0) else { return }
      samples.withUnsafeBufferPointer { frames in recording.samples.withLock { $0 += frames } }
    }
    defer { unit.removeTap(onBus: 0) }
    try await Task.sleep(for: .milliseconds(200))
    engine.playLive([0x90, note, 100], onTrack: trackID)
    try await Task.sleep(for: .milliseconds(400))
    let held = recording.samples.withLock { samples in
      let level = samples.map(abs).max() ?? 0
      samples = []
      return level
    }
    engine.playLive([0x80, note, 0], onTrack: trackID)
    try await Task.sleep(for: .milliseconds(150))
    recording.samples.withLock { $0 = [] }
    try await Task.sleep(for: .milliseconds(150))
    return (held, recording.samples.withLock { $0 }.map(abs).max() ?? 0)
  }

  /// An SFZ instrument plays through a sampler preset made from it: its key ranges,
  /// velocity layers, sample offsets and release.
  @Test func sfzInstrumentsPlayFromTheirLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SFZ-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "SFZ Library")
    try FileManager.default.createDirectory(at: library.appending(path: "Tones/Samples"), withIntermediateDirectories: true)
    try EXSTestFiles.writeTones([(440, 88200)], to: library.appending(path: "Tones/Samples/A4.wav"))
    try EXSTestFiles.writeTones([(659.25, 88200)], to: library.appending(path: "Tones/Samples/E5.wav"))
    // A low tone, then the one the region plays from its offset.
    try EXSTestFiles.writeTones([(220, 44100), (880, 88200)], to: library.appending(path: "Tones/Samples/Two.wav"))
    try """
      <control> default_path=Samples/
      <group> ampeg_release=0.8
      <region> sample=A4.wav lokey=0 hikey=70 pitch_keycenter=69 hivel=80
      <region> sample=E5.wav lokey=0 hikey=70 pitch_keycenter=69 lovel=81
      <region> sample=Two.wav lokey=71 hikey=127 pitch_keycenter=81 offset=44100
      """.write(to: library.appending(path: "Tones/Tones.sfz"), atomically: true, encoding: .utf8)

    let suite = "SFZ-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let libraries = SoundLibraries(defaults: defaults, indexDirectory: root.appending(path: "Indexes"))
    let id = try libraries.add(library)
    for _ in 0..<100 where libraries.library(withID: id)?.scanned == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(libraries.library(withID: id)?.count(of: .instrument) == 1)
    let url = try await libraries.url(for: SamplerInstrument(libraryID: id, libraryName: "SFZ Library", path: "Tones/Tones.sfz"))
    #expect(url.pathExtension == "aupreset")

    let previous = SamplerInstrumentResolver.resolve
    SamplerInstrumentResolver.resolve = { _ in url }
    defer { SamplerInstrumentResolver.resolve = previous }
    var track = Track(name: "Tones", kind: .softwareInstrument)
    track.channel.instrument = .sampler(SamplerInstrument(libraryID: id, libraryName: "SFZ Library", path: "Tones/Tones.sfz"))
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")

    // Zero crossings a second are twice the frequency.
    let soft = try await brightness(of: engine, playingOn: track.id, note: 69, velocity: 60)
    #expect(abs(soft - 880) < 30, "Soft A4: \(soft)")
    try await Task.sleep(for: .seconds(1.2))
    let loud = try await brightness(of: engine, playingOn: track.id, note: 69, velocity: 110)
    #expect(abs(loud - 1318.5) < 40, "Loud A4 plays the loud layer: \(loud)")
    // Let the 0.8 s release of the notes before die away.
    try await Task.sleep(for: .seconds(1.2))
    let offset = try await brightness(of: engine, playingOn: track.id, note: 81, velocity: 100)
    #expect(abs(offset - 1760) < 60, "A5 starts past the low tone: \(offset)")

    // The 0.8 s release keeps sounding after the key is let go.
    try await Task.sleep(for: .seconds(1.2))
    let ringing = try await levels(of: engine, playingOn: track.id, note: 69)
    #expect(ringing.held > 0.05, "Sounds while held: \(ringing.held)")
    #expect(ringing.released > ringing.held / 4, "Release: \(ringing)")
  }

  private final class Recording: @unchecked Sendable {
    let samples = Mutex<[Float]>([])
  }

  /// Plays middle C on a track and counts how often its instrument's output crosses zero per
  /// second: a simple measure of how bright the sound is.
  func brightness(of engine: PlaybackEngine, playingOn trackID: Track.ID, note: UInt8 = 60, velocity: UInt8 = 110) async throws -> Double {
    let unit = try #require(engine.instruments[trackID]?.instrument)
    let format = unit.outputFormat(forBus: 0)
    let recording = Recording()
    try unit.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      guard case .float(let samples) = buffer.channelData(0) else { return }
      samples.withUnsafeBufferPointer { frames in
        recording.samples.withLock { $0 += frames }
      }
    }
    defer { unit.removeTap(onBus: 0) }
    try await Task.sleep(for: .milliseconds(200))
    recording.samples.withLock { $0 = [] }
    engine.playLive([0x90, note, velocity], onTrack: trackID)
    try await Task.sleep(for: .milliseconds(600))
    engine.playLive([0x80, note, 0], onTrack: trackID)

    let samples = recording.samples.withLock { $0 }
    // Skip the attack and measure the sustained part of the note.
    let onset = try #require(samples.firstIndex { abs($0) > 0.01 }, "The note should sound")
    let window = samples.dropFirst(onset + 2_000).prefix(8_192)
    try #require(window.count == 8_192, "The note should last long enough to measure")
    let crossings = zip(window, window.dropFirst()).count { ($0 < 0) != ($1 < 0) }
    return Double(crossings) * format.sampleRate / Double(window.count)
  }
}
