//
//  SoundLibraryTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Reading loop tags from audio files, and indexing library folders. The files are built
/// here byte by byte, in each format's layout.
struct SoundLibraryTests {
  // MARK: - Building files

  static func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
  }

  static func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
  }

  static func strings(_ pairs: [(String, String)]) -> [UInt8] {
    pairs.flatMap { Array($0.0.utf8) + [0] + Array($0.1.utf8) + [0] }
  }

  /// A CAF of 16-bit stereo PCM with Apple Loops tags and, optionally, a MIDI chunk.
  static func caf(frames: Int, sampleRate: Double = 44100, tags: [(String, String)], midi: [UInt8]? = nil) -> Data {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      Array(type.utf8) + bigEndian(UInt64(body.count), 8) + body
    }
    var bytes = Array("caff".utf8) + bigEndian(1, 2) + bigEndian(0, 2)
    let desc = bigEndian(sampleRate.bitPattern, 8) + Array("lpcm".utf8) + bigEndian(0, 4)
      + bigEndian(4, 4) + bigEndian(1, 4) + bigEndian(2, 4) + bigEndian(16, 4)
    bytes += chunk("desc", desc)
    bytes += chunk("data", bigEndian(0, 4) + [UInt8](repeating: 0, count: frames * 4))
    let loopTags = AudioFileMetadata.appleLoopsUUID + bigEndian(UInt64(tags.count), 4) + strings(tags)
    bytes += chunk("uuid", loopTags)
    if let midi { bytes += chunk("midi", midi) }
    return Data(bytes)
  }

  /// An AIFF of 16-bit mono with an Apple Loops `basc` chunk.
  static func aiff(frames: Int, beats: Int, root: Int, scale: Int, oneShot: Bool = false) -> Data {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      Array(type.utf8) + bigEndian(UInt64(body.count), 4) + body + (body.count % 2 == 1 ? [0] : [])
    }
    // 44100 as an 80-bit extended float.
    let rate: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
    let comm = bigEndian(1, 2) + bigEndian(UInt64(frames), 4) + bigEndian(16, 2) + rate
    let basc = bigEndian(1, 4) + bigEndian(UInt64(beats), 4) + bigEndian(UInt64(root), 2) + bigEndian(UInt64(scale), 2)
      + bigEndian(4, 2) + bigEndian(4, 2) + bigEndian(oneShot ? 1 : 0, 2) + [UInt8](repeating: 0, count: 66)
    let body = Array("AIFF".utf8) + chunk("COMM", comm) + chunk("basc", basc)
      + chunk("SSND", bigEndian(0, 8) + [UInt8](repeating: 0, count: frames * 2))
    return Data(Array("FORM".utf8) + bigEndian(UInt64(body.count), 4) + body)
  }

  /// A WAV of 16-bit stereo with an ACID chunk and an INFO list.
  static func wav(frames: Int, sampleRate: Int = 48000, tempo: Float?, beats: Int, root: Int?, oneShot: Bool = false, genre: String? = nil) -> Data {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      Array(type.utf8) + littleEndian(UInt64(body.count), 4) + body + (body.count % 2 == 1 ? [0] : [])
    }
    let fmt = littleEndian(1, 2) + littleEndian(2, 2) + littleEndian(UInt64(sampleRate), 4)
      + littleEndian(UInt64(sampleRate * 4), 4) + littleEndian(4, 2) + littleEndian(16, 2)
    var body = Array("WAVE".utf8) + chunk("fmt ", fmt)
    if let tempo {
      let flags: UInt64 = (oneShot ? 1 : 0) | (root != nil ? 2 : 0)
      let acid = littleEndian(flags, 4) + littleEndian(UInt64(root ?? 60), 2) + littleEndian(0x8000, 2) + littleEndian(0, 4)
        + littleEndian(UInt64(beats), 4) + littleEndian(4, 2) + littleEndian(4, 2) + littleEndian(UInt64(tempo.bitPattern), 4)
      body += chunk("acid", acid)
    }
    if let genre {
      let info = Array("INFO".utf8) + chunk("IGNR", Array(genre.utf8) + [0]) + chunk("IKEY", Array("Dark; Gritty".utf8) + [0])
      body += chunk("LIST", info)
    }
    body += chunk("data", [UInt8](repeating: 0, count: frames * 4))
    return Data(Array("RIFF".utf8) + littleEndian(UInt64(body.count), 4) + body)
  }

  // MARK: - Reading

  @Test func readsAppleLoopTagsFromCAF() throws {
    // Eight beats in 4 seconds: 120 BPM.
    let data = Self.caf(frames: 176_400, tags: [
      ("beat count", "8"), ("key signature", "E"), ("key type", "minor"), ("time signature", "4/4"),
      ("category", "Strings"), ("subcategory", "Ensemble"), ("genre", "Orchestral"), ("descriptors", "Acoustic,Melodic"),
    ], midi: Array("MThd".utf8) + [0, 0, 0, 6])
    let metadata = try AudioFileMetadata.read(data, includingMIDI: true)
    #expect(metadata.frameCount == 176_400)
    #expect(metadata.sampleRate == 44100)
    #expect(metadata.beats == 8)
    #expect(abs((metadata.tempo ?? 0) - 120) < 0.001)
    #expect(metadata.key == KeySignature(tonic: 4, mode: .minor))
    #expect(metadata.timeSignature == .fourFour)
    #expect(metadata.category == "Strings")
    #expect(metadata.genre == "Orchestral")
    #expect(metadata.descriptors == ["Acoustic", "Melodic"])
    #expect(metadata.hasMIDI)
    #expect(metadata.midi?.prefix(4) == Data("MThd".utf8))
    #expect(metadata.isLoop)
  }

  @Test func readsAppleLoopBascChunkFromAIFF() throws {
    // Four beats in 2 seconds at 44.1 kHz; root note 62 (D), major.
    let metadata = try AudioFileMetadata.read(Self.aiff(frames: 88_200, beats: 4, root: 62, scale: 2))
    #expect(metadata.sampleRate == 44100)
    #expect(metadata.frameCount == 88_200)
    #expect(abs((metadata.tempo ?? 0) - 120) < 0.001)
    #expect(metadata.key == KeySignature(tonic: 2, mode: .major))
    #expect(metadata.isLoop)

    // Untuned loops ("neither" scale) have no key; one-shots aren't loops.
    let drums = try AudioFileMetadata.read(Self.aiff(frames: 88_200, beats: 4, root: 60, scale: 3))
    #expect(drums.keyTonic == nil)
    let hit = try AudioFileMetadata.read(Self.aiff(frames: 4410, beats: 0, root: 60, scale: 3, oneShot: true))
    #expect(!hit.isLoop)
  }

  @Test func readsACIDTagsFromWAV() throws {
    let data = Self.wav(frames: 96_000, tempo: 95, beats: 4, root: 69, genre: "Hip Hop")
    let metadata = try AudioFileMetadata.read(data)
    #expect(metadata.sampleRate == 48000)
    #expect(metadata.frameCount == 96_000)
    #expect(metadata.statedTempo == 95)
    #expect(metadata.beats == 4)
    #expect(metadata.keyTonic == 9)
    #expect(metadata.genre == "Hip Hop")
    #expect(metadata.descriptors == ["Dark", "Gritty"])
    #expect(metadata.isLoop)

    let oneShot = try AudioFileMetadata.read(Self.wav(frames: 4800, tempo: 120, beats: 0, root: nil, oneShot: true))
    #expect(!oneShot.isLoop)
    #expect(oneShot.keyTonic == nil)
  }

  @Test func readsTempoAndKeyFromNames() {
    // Two seconds at 120 BPM is four beats.
    var metadata = AudioFileMetadata()
    metadata.sampleRate = 48000
    metadata.frameCount = 96_000
    metadata.guessFromName("Deep_Bass_Loop_120bpm_C#min")
    #expect(metadata.statedTempo == 120)
    #expect(metadata.beats == 4)
    #expect(metadata.key == KeySignature(tonic: 1, mode: .minor))
    #expect(metadata.isLoop)

    var spaced = AudioFileMetadata()
    spaced.guessFromName("Keys 92 BPM F♯ minor")
    #expect(spaced.statedTempo == 92)
    #expect(spaced.key == KeySignature(tonic: 6, mode: .minor))

    // "Drum" ends in "m" but isn't D minor; bare letters aren't keys.
    var drum = AudioFileMetadata()
    drum.guessFromName("Drum Hit A 01")
    #expect(drum.keyTonic == nil)
    var am = AudioFileMetadata()
    am.guessFromName("Piano Am 01")
    #expect(am.key == KeySignature(tonic: 9, mode: .minor))
  }

  @Test func unknownFilesAreRejected() {
    #expect(throws: AudioFileMetadata.ReadError.self) { try AudioFileMetadata.read(Data("ID3 not audio".utf8)) }
  }

  // MARK: - Items

  @Test func classifiesFamiliesFromTagsNamesAndFolders() {
    #expect(SoundCategory.classify(["Synth Bass 03"]) == .bass)
    #expect(SoundCategory.classify(["Bass Drum Hit"]) == .drums)
    #expect(SoundCategory.classify(["Bassoon Phrase"]) == .woodwind)
    #expect(SoundCategory.classify(["Warm Electric Piano"]) == .keys)
    #expect(SoundCategory.classify(["Untitled 4", "Kicks", "My Pack"]) == .drums)
    #expect(SoundCategory.classify(["Strings", "Hip Hop Beat"]) == .strings)
    #expect(SoundCategory.classify(["Single Take 2"]) == nil)
  }

  @Test func loopsMoveToTheNearestMatchingKey() {
    let eMinor = SoundLibraryItem(path: "a.caf", kind: .loop, keyTonic: 4, keyMode: .minor)
    // E minor into A minor: up 5. Into G major (relative minor E): no change.
    #expect(eMinor.semitones(toMatch: KeySignature(tonic: 9, mode: .minor)) == 5)
    #expect(eMinor.semitones(toMatch: KeySignature(tonic: 7, mode: .major)) == 0)
    let c = SoundLibraryItem(path: "b.caf", kind: .loop, keyTonic: 0, keyMode: .major)
    // C into A♭ major: down 4 rather than up 8.
    #expect(c.semitones(toMatch: KeySignature(tonic: 8, mode: .major)) == -4)
    let drums = SoundLibraryItem(path: "c.caf", kind: .loop)
    #expect(drums.semitones(toMatch: KeySignature(tonic: 5, mode: .major)) == 0)
  }

  @Test func filtersByKindFamilyKeyTempoAndWords() {
    let items = [
      SoundLibraryItem(path: "Pack/Bass/Funky Bass 01.wav", kind: .loop, tempo: 100, keyTonic: 9, category: .bass),
      SoundLibraryItem(path: "Pack/Drums/Kick 01.wav", kind: .oneShot, category: .drums),
      SoundLibraryItem(path: "Pack/Keys/Rhodes Chords.caf", kind: .loop, tempo: 90, keyTonic: 0, category: .keys, hasMIDI: true),
    ]
    func names(_ filter: SoundLibraryFilter) -> [String] {
      let words = filter.searchWords
      return items.filter { filter.matches($0, searchText: $0.searchText, words: words) }.map(\.name)
    }
    var filter = SoundLibraryFilter()
    #expect(names(filter).count == 3)
    filter.text = "FUNKY"
    #expect(names(filter) == ["Funky Bass 01"])
    filter = SoundLibraryFilter()
    filter.kinds = [.loop]
    filter.tempoRange = 85...95
    #expect(names(filter) == ["Rhodes Chords"])
    filter = SoundLibraryFilter()
    filter.categories = [.drums]
    #expect(names(filter) == ["Kick 01"])
    filter = SoundLibraryFilter()
    filter.midiOnly = true
    #expect(names(filter) == ["Rhodes Chords"])
    filter = SoundLibraryFilter()
    filter.text = "keys"  // a folder name
    #expect(names(filter) == ["Rhodes Chords"])
  }

  @Test func itemsSurviveTheIndexRoundTrip() throws {
    let item = SoundLibraryItem(
      path: "Loops/Strings 01.caf", kind: .loop, modified: 12, size: 34, duration: 4, beats: 8, tempo: 120,
      keyTonic: 4, keyMode: .minor, timeSignature: .fourFour, category: .strings, genre: "Orchestral",
      tags: ["Ensemble"], hasMIDI: true)
    let index = SoundLibraryIndex(items: [item, SoundLibraryItem(path: "Kick.wav", kind: .oneShot)])
    let decoded = try JSONDecoder().decode(SoundLibraryIndex.self, from: JSONEncoder().encode(index))
    #expect(decoded.items == index.items)
  }

  // MARK: - Scanning

  @Test func scansFoldersAndReusesUnchangedEntries() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SoundLibraryTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root.appending(path: "Drums"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appending(path: "Song.logicx/Media"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appending(path: "Instruments"), withIntermediateDirectories: true)
    try Self.wav(frames: 96_000, tempo: 120, beats: 4, root: nil).write(to: root.appending(path: "Drums/Beat 120.wav"))
    try Self.wav(frames: 4800, tempo: nil, beats: 0, root: nil).write(to: root.appending(path: "Drums/Snare.wav"))
    try Self.wav(frames: 4800, tempo: nil, beats: 0, root: nil).write(to: root.appending(path: "Song.logicx/Media/Take.wav"))
    try Data("<group>".utf8).write(to: root.appending(path: "Instruments/Organ.sfz"))
    try FileManager.default.createDirectory(at: root.appending(path: "Impulse Responses"), withIntermediateDirectories: true)
    try Self.aiff(frames: 4410, beats: 0, root: 60, scale: 3, oneShot: true).write(to: root.appending(path: "Impulse Responses/Hall.wav"))
    try Self.aiff(frames: 4410, beats: 0, root: 60, scale: 3, oneShot: true).write(to: root.appending(path: "Drums/Room.SDIR"))
    try Data("notes".utf8).write(to: root.appending(path: "Readme.txt"))

    let everything = try SoundLibraryScanner.scan(root)
    #expect(everything.map(\.path) == [
      "Drums/Beat 120.wav", "Drums/Room.SDIR", "Drums/Snare.wav", "Impulse Responses/Hall.wav", "Instruments/Organ.sfz",
    ])
    // Space Designer files and audio in an impulse responses folder are impulse responses.
    #expect(everything[1].kind == .impulseResponse)
    #expect(everything[1].duration == 0.1)
    #expect(everything[3].kind == .impulseResponse)
    let items = everything.filter { $0.kind != .impulseResponse }
    #expect(items[0].kind == .loop)
    #expect(items[0].tempo == 120)
    #expect(items[0].category == .drums)
    #expect(items[1].kind == .oneShot)
    #expect(items[2].kind == .instrument)
    #expect(items[2].category == .keys)

    // An unchanged file keeps its entry, even if (as here) the entry differs from the file.
    var previous = everything
    previous[2].genre = "Remembered"
    let rescanned = try SoundLibraryScanner.scan(root, reusing: previous)
    #expect(rescanned[2].genre == "Remembered")
  }

  // MARK: - Following the key

  @Test func transposedAudioRegionsAreRendered() throws {
    let file = AudioFileReference(fileName: "Loop.caf", sampleRate: 48000, channelCount: 1, frameCount: 96_000)
    let region = Region(
      name: "Loop", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)), transpose: 3)
    var project = Project(tracks: [Track(name: "Loop", kind: .audio, regions: [region])], audioFiles: [file])
    // Flex is off on the track, but the region is still rendered, transposed.
    let key = try #require(project.flexRenderKey(for: region, on: project.tracks[0]))
    #expect(key.transpose == 3)
    #expect(key.mode == .rhythmic)

    try SetRegionParameter(.transpose(0), for: [region.id]).apply(to: &project)
    #expect(project.flexRenderKey(for: project.tracks[0].regions[0], on: project.tracks[0]) == nil)
  }

  @Test func transposingShiftsPitchButKeepsTheLength() {
    let rate = 48000.0
    let sine = (0..<48000).map { Float(sin(2 * Double.pi * 220 * Double($0) / rate)) * 0.5 }
    let map = FlexMap(markers: [], duration: 1)
    let rendered = FlexRenderer.render([sine], map: map, mode: .rhythmic, transpose: 12, sampleRate: rate)
    #expect(rendered[0].count == sine.count)
    // Count rising zero crossings in the middle half second: an octave up is about 440.
    let middle = Array(rendered[0][12000..<36000])
    let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    #expect(abs(crossings * 2 - 440) < 12, "\(crossings * 2) Hz")
  }

  // MARK: - Instruments

  static func riffChunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + littleEndian(UInt64(body.count), 4) + body + (body.count % 2 == 1 ? [0] : [])
  }

  static func riffList(_ type: String, _ chunks: [UInt8]) -> [UInt8] {
    riffChunk("LIST", Array(type.utf8) + chunks)
  }

  @Test func listsSoundFontPresets() throws {
    func record(_ name: String, program: Int, bank: Int) -> [UInt8] {
      let nameBytes = Array(name.utf8.prefix(20)) + [UInt8](repeating: 0, count: max(0, 20 - name.utf8.count))
      return nameBytes + Self.littleEndian(UInt64(program), 2) + Self.littleEndian(UInt64(bank), 2) + [UInt8](repeating: 0, count: 14)
    }
    let phdr = record("Warm Pad", program: 89, bank: 0) + record("Grand Piano", program: 0, bank: 0)
      + record("Standard Kit", program: 0, bank: 128) + record("EOP", program: 0, bank: 0)
    let body = Array("sfbk".utf8) + Self.riffList("INFO", Self.riffChunk("ifil", [2, 0, 1, 0]))
      + Self.riffList("pdta", Self.riffChunk("phdr", phdr))
    let presets = try SoundBankReader.presets(in: Data(Array("RIFF".utf8) + Self.littleEndian(UInt64(body.count), 4) + body))
    #expect(presets.map(\.name) == ["Grand Piano", "Warm Pad", "Standard Kit"])
    #expect(presets.map(\.program) == [0, 89, 0])
    #expect(presets.last?.isPercussion == true)
  }

  @Test func listsDLSInstruments() throws {
    func instrument(_ name: String, bank: UInt64, program: UInt64) -> [UInt8] {
      Self.riffList("ins ", Self.riffChunk("insh", Self.littleEndian(1, 4) + Self.littleEndian(bank, 4) + Self.littleEndian(program, 4))
        + Self.riffList("INFO", Self.riffChunk("INAM", Array(name.utf8) + [0])))
    }
    let lins = Self.riffList("lins", instrument("Strings", bank: 0, program: 48) + instrument("Room Kit", bank: 0x8000_0000, program: 8))
    let body = Array("DLS ".utf8) + Self.riffChunk("colh", Self.littleEndian(2, 4)) + lins
    let presets = try SoundBankReader.presets(in: Data(Array("RIFF".utf8) + Self.littleEndian(UInt64(body.count), 4) + body))
    #expect(presets == [
      SoundBankPreset(name: "Strings", program: 48, bank: 0, isPercussion: false),
      SoundBankPreset(name: "Room Kit", program: 8, bank: 0, isPercussion: true),
    ])
  }

  /// An EXS instrument: a header chunk, a zone chunk and two sample chunks, little-endian.
  static func exs(samples: [(folder: String, file: String)], zoneSize: Int = 104) -> Data {
    func chunk(type: UInt64, name: String, body: [UInt8]) -> [UInt8] {
      let nameBytes = Array(name.utf8.prefix(64)) + [UInt8](repeating: 0, count: max(0, 64 - name.utf8.count))
      return littleEndian(0x0000_0101 | type << 24, 4) + littleEndian(UInt64(body.count), 4) + littleEndian(0, 4)
        + littleEndian(0, 4) + Array("TBOS".utf8) + nameBytes + body
    }
    func field(_ text: String) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: 256 - text.utf8.count) }
    var bytes = chunk(type: 0, name: "Test Keys", body: [UInt8](repeating: 0, count: 40))
    bytes += chunk(type: 1, name: "Zone", body: (0..<zoneSize).map { UInt8(truncatingIfNeeded: $0) })
    for sample in samples {
      // 80 bytes of format fields, the folder, the file name, then padding to 592.
      bytes += chunk(type: 3, name: sample.file, body: [UInt8](repeating: 0, count: 80) + field(sample.folder) + field(sample.file))
    }
    return Data(bytes)
  }

  @Test func exsSamplesAreReadAndRelocated() throws {
    let data = Self.exs(samples: [("/Library/Old Place/Keys", "Key C3.aif"), ("/Library/Old Place/Keys", "Key C4.aif")])
    let instrument = try #require(EXSInstrument(data: data))
    #expect(instrument.samples.map(\.path) == ["/Library/Old Place/Keys/Key C3.aif", "/Library/Old Place/Keys/Key C4.aif"])

    // Only the first is found somewhere new; the other is left as it was.
    let moved = try #require(instrument.relocatingSamples { $0.fileName == "Key C3.aif" ? "/Volumes/Sounds/Keys" : nil })
    let reread = try #require(EXSInstrument(data: moved))
    #expect(reread.samples.map(\.path) == ["/Volumes/Sounds/Keys/Key C3.aif", "/Library/Old Place/Keys/Key C4.aif"])
    #expect(moved.count == data.count)
    #expect(instrument.relocatingSamples { _ in nil } == nil, "Nothing changed")
    #expect(EXSInstrument(data: Data("not an instrument at all, no magic here at all..........................................".utf8)) == nil)
  }

  @Test func libraryInstrumentsAreSavedInSongs() throws {
    let preset = SoundBankPreset(name: "Warm Pad", program: 89, bank: 0, isPercussion: false)
    let source = InstrumentSource.sampler(SamplerInstrument(libraryID: UUID(), libraryName: "Pads", path: "Banks/Pads.sf2", preset: preset))
    let decoded = try JSONDecoder().decode(InstrumentSource.self, from: JSONEncoder().encode(source))
    #expect(decoded == source)
    #expect(source.displayName == "Warm Pad")
    #expect(InstrumentSource.sampler(SamplerInstrument(libraryID: nil, libraryName: "X", path: "Keys/Rhodes.exs")).displayName == "Rhodes")
    #expect(SamplerInstrument.isPlayable("a/b.exs"))
    #expect(SamplerInstrument.isPlayable("a/b.sfz"))
    #expect(!SamplerInstrument.isPlayable("a/b.wav"))
  }

  @Test func newerZonesAreCutBackToTheClassicLayout() throws {
    let data = Self.exs(samples: [("/Samples", "A.wav")], zoneSize: 148)
    let instrument = try #require(EXSInstrument(data: data))
    #expect(instrument.hasLongZones)
    let classic = try #require(instrument.withClassicZones())
    #expect(classic.count == data.count - 40)
    let reread = try #require(EXSInstrument(data: classic))
    #expect(reread.zones.map(\.size) == [108])
    #expect(!reread.hasLongZones)
    #expect(reread.samples.map(\.path) == ["/Samples/A.wav"], "Later chunks are still found")
    // The classic fields are kept as they were.
    let zoneBody = reread.zones[0].offset + 84
    #expect([UInt8](classic[zoneBody..<(zoneBody + 108)]) == (0..<108).map { UInt8($0) })
    #expect(EXSInstrument(data: Self.exs(samples: [("/Samples", "A.wav")], zoneSize: 108))?.withClassicZones() == nil)
  }

  /// An EXS instrument with two groups, velocities 0–70 at +8 dB and 71–127, a zone in
  /// each, and a zone with a velocity range of its own in the first; in any of the layouts
  /// files come in: little- or big-endian, with or without 0x80 in each chunk's type byte.
  static func groupedEXS(bigEndian: Bool, flagged: Bool) -> Data {
    func number(_ value: UInt64, _ count: Int) -> [UInt8] {
      bigEndian ? littleEndian(value, count).reversed() : littleEndian(value, count)
    }
    func chunk(type: UInt8, body: [UInt8]) -> [UInt8] {
      let flag: UInt64 = flagged ? 0x8000 : 0
      let magic = ["TBOS", "JBOS", "SOBT", "SOBJ"][(bigEndian ? 2 : 0) + (flagged ? 1 : 0)]
      return [bigEndian ? 0 : 1, 1, 0, type | (flagged ? 0x80 : 0)] + number(UInt64(body.count) | flag, 4) + [UInt8](repeating: 0, count: 8)
        + Array(magic.utf8) + [UInt8](repeating: 0, count: 64) + body
    }
    func zone(group: UInt64, velocities: ClosedRange<UInt8>? = nil, volume: Int8 = 0) -> [UInt8] {
      var body = [UInt8](repeating: 0, count: 108)
      body[4] = UInt8(bitPattern: volume)
      body[7] = 127
      body[10] = 127
      if let velocities {
        body[0] = 0x08
        body[9] = velocities.lowerBound
        body[10] = velocities.upperBound
      }
      body.replaceSubrange(88..<92, with: number(group, 4))
      return chunk(type: 1, body: body)
    }
    func group(velocities: ClosedRange<UInt8>, volume: Int8) -> [UInt8] {
      var body = [UInt8](repeating: 0, count: 96)
      body[0] = UInt8(bitPattern: volume)
      body[5] = velocities.lowerBound
      body[6] = velocities.upperBound
      return chunk(type: 2, body: body)
    }
    let bytes = chunk(type: 0, body: [UInt8](repeating: 0, count: 40))
      + zone(group: 0, volume: -2) + zone(group: 1) + zone(group: 0, velocities: 50...100)
      + group(velocities: 0...70, volume: 8) + group(velocities: 71...127, volume: 0)
    return Data(bytes)
  }

  @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
  func groupVelocitiesAndVolumesArePutOnZones(bigEndian: Bool, flagged: Bool) throws {
    let instrument = try #require(EXSInstrument(data: Self.groupedEXS(bigEndian: bigEndian, flagged: flagged)))
    #expect(instrument.zones.count == 3)
    #expect(instrument.groups.count == 2)
    let fixed = try #require(instrument.withGroupSettingsOnZones())
    let reread = try #require(EXSInstrument(data: fixed))
    let bodies = reread.zones.map { [UInt8](fixed[($0.offset + 84)..<($0.offset + 84 + $0.size)]) }
    // Options (velocity range on), volume, lowest and highest velocity.
    func fields(_ body: [UInt8]) -> [Int] { [Int(body[0]), Int(Int8(bitPattern: body[4])), Int(body[9]), Int(body[10])] }
    #expect(fields(bodies[0]) == [0x08, 6, 0, 70])
    #expect(fields(bodies[1]) == [0x08, 0, 71, 127])
    #expect(fields(bodies[2]) == [0x08, 8, 50, 70], "Within the zone's own range")
  }

  @Test func groupsOfEveryVelocityAtUnityLeaveTheInstrumentAlone() throws {
    let data = Self.exs(samples: [("/Samples", "A.wav")], zoneSize: 108)
    #expect(EXSInstrument(data: data)?.withGroupSettingsOnZones() == nil)
  }

  // MARK: - SFZ

  @Test func sfzRegionsInheritFromTheirHeaders() {
    let text = """
      // A small piano.
      <control> default_path=Samples\\ octave_offset=0
      #define $SOFT 64
      <global> ampeg_release=0.6 volume=-2
      <group> lovel=1 hivel=$SOFT
      <region> sample=Piano C4 soft.wav key=c4
      <region> sample=Piano C5 soft.wav lokey=c#4 hikey=127 pitch_keycenter=72 tune=-12
      <group> lovel=65 hivel=127 ampeg_release=0.3 /* loud layer */
      <region> sample=Piano C4 loud.wav lokey=0 hikey=60 pitch_keycenter=60 offset=200 end=44000 loop_mode=loop_continuous
      """
    let sfz = SFZInstrument(text: text)
    #expect(sfz.regions.map(\.sample) == ["Samples/Piano C4 soft.wav", "Samples/Piano C5 soft.wav", "Samples/Piano C4 loud.wav"])
    #expect(sfz.regions[0].keys == 60...60)
    #expect(sfz.regions[0].rootKey == 60)
    #expect(sfz.regions[0].velocities == 1...64)
    #expect(sfz.regions[0].volume == -2)
    #expect(sfz.regions[0].envelope.release == 0.6)
    #expect(sfz.regions[1].keys == 61...127)
    #expect(sfz.regions[1].rootKey == 72)
    #expect(sfz.regions[1].tune == -12)
    #expect(sfz.regions[2].velocities == 65...127)
    #expect(sfz.regions[2].envelope.release == 0.3)
    #expect(sfz.regions[2].offset == 200)
    #expect(sfz.regions[2].end == 44000)
    #expect(sfz.regions[2].loops)
    #expect(!sfz.regions[0].loops)
  }

  @Test func sfzIncludesAlternativesAndNoteNames() {
    let main = """
      #include "keys.sfz"
      <region> sample=release.wav trigger=release
      <region> sample=rr2.wav seq_position=2 key=40
      <region> sample=rr1.wav seq_position=1 key=40
      <region> sample=off.wav end=-1
      <region> sample=sw1.wav sw_last=24 sw_default=24
      <region> sample=sw2.wav sw_last=25
      """
    let sfz = SFZInstrument(text: main) { path in path == "keys.sfz" ? "<region> sample=sub/a.wav lokey=a3 hikey=bb3" : nil }
    #expect(sfz.regions.map(\.sample) == ["sub/a.wav", "rr1.wav", "sw1.wav"])
    #expect(sfz.regions[0].keys == 57...58)
    #expect(SFZInstrument.noteNumber("c-1") == 0)
    #expect(SFZInstrument.noteNumber("C4") == 60)
    #expect(SFZInstrument.noteNumber("f#3") == 54)
    #expect(SFZInstrument.noteNumber("db4") == 61)
    #expect(SFZInstrument.noteNumber("c4", octaveOffset: 1) == 72)
    #expect(SFZInstrument.noteNumber("x") == nil)
  }

  @Test func sfzBecomesAnAppleSamplerPreset() throws {
    let sfz = SFZInstrument(text: """
      <group> ampeg_release=0.5
      <region> sample=a.wav lokey=0 hikey=70 pitch_keycenter=69 transpose=1 tune=30 volume=-6 pan=50 offset=100
      <region> sample=a.wav lokey=71 hikey=100 pitch_keycenter=81
      <region> sample=a.wav lokey=101 hikey=127 pitch_keycenter=81 ampeg_release=0
      <region> sample=missing.wav key=10
      """)
    let preset = SamplerPreset.make(sfz, name: "Test") { $0 == "missing.wav" ? nil : URL(fileURLWithPath: "/Samples/\($0)") }
    let references = try #require(preset["file-references"] as? [String: String])
    #expect(Array(references.values) == ["/Samples/a.wav"], "One file, used twice; the missing one is left out")
    let instrument = try #require(preset["Instrument"] as? [String: Any])
    let layers = try #require(instrument["Layers"] as? [[String: Any]])
    #expect(layers.count == 1)
    #expect((layers[0]["Zones"] as? [[String: Any]])?.count == 3)
    let zone = try #require((layers[0]["Zones"] as? [[String: Any]])?.first)
    #expect(zone["root key"] as? Int == 69)
    #expect(zone["max key"] as? Int == 70)
    #expect(zone["coarse tune"] as? Int == 1)
    #expect(zone["fine tune"] as? Double == 30)
    #expect(zone["gain"] as? Double == -6)
    #expect(zone["pan"] as? Double == 0.5)
    #expect(zone["sample start"] as? Int == 100)
    let stages = try #require((layers[0]["Envelopes"] as? [[String: Any]])?.first?["Stages"] as? [[String: Any]])
    #expect(stages.first { $0["stage"] as? Int == 5 }?["time"] as? Double == 0.5, "The envelope most regions use")
    #expect(PropertyListSerialization.propertyList(preset, isValidFor: .binary))
  }
}
