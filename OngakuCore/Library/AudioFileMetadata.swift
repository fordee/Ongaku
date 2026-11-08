//
//  AudioFileMetadata.swift
//  OngakuCore
//

import Foundation

/// What an audio file says about itself as a loop or sample: its length, and the tags loop
/// libraries write into it. Read straight from the file's chunks, without decoding audio, so
/// a library of tens of thousands of files can be indexed quickly.
///
/// Understands the tags of the common loop formats:
/// - **Apple Loops** (CAF and AIFF, as Logic, GarageBand and many sample packs ship them):
///   beats, key, meter, category, genre and descriptors; MIDI loops also carry a Standard
///   MIDI File of what they play.
/// - **ACID loops** (WAV): beats, tempo, root note and whether it's a one-shot.
/// - WAV `LIST`/`INFO` genre and keywords.
///
/// Files without tags often say their tempo and key in their names (“Bass 124 BPM Am.wav”),
/// which `guessFromName` reads.
public struct AudioFileMetadata: Sendable, Equatable {
  public var sampleRate: Double?
  public var frameCount: Int64?
  /// Beats the loop lasts, as tagged (or worked out from a tempo in its name).
  public var beats: Int?
  /// The tempo the file states (ACID tags, names); otherwise it's worked out from `beats`.
  public var statedTempo: Double?
  /// Pitch class of the key (0 is C), for tonal loops.
  public var keyTonic: Int?
  /// `nil` when a key's mode isn't stated, or the loop is neither major nor minor.
  public var keyMode: KeySignature.Mode?
  public var timeSignature: TimeSignature?
  /// Tagged as a one-shot (a single hit or note) rather than a loop.
  public var isOneShot = false
  public var category: String?
  public var subcategory: String?
  public var genre: String?
  public var descriptors: [String] = []
  /// Whether the file carries a Standard MIDI File of what it plays (Apple's MIDI loops).
  public var hasMIDI = false
  /// The embedded MIDI file, when read with `includingMIDI`.
  public var midi: Data?

  public init() {}

  public var duration: Double? {
    guard let sampleRate, let frameCount, sampleRate > 0 else { return nil }
    return Double(frameCount) / sampleRate
  }

  /// The loop's tempo: as stated, or from its beats and length.
  public var tempo: Double? {
    if let statedTempo, statedTempo > 0 { return statedTempo }
    guard let beats, beats > 0, let duration, duration > 0 else { return nil }
    // Beats count in the meter's beat unit; tempo is in quarter notes.
    let quarterNotesPerBeat = 4 / Double(timeSignature?.beatUnit ?? 4)
    return Double(beats) * quarterNotesPerBeat * 60 / duration
  }

  /// Whether it can follow a song's tempo: it has a tempo and isn't a one-shot.
  public var isLoop: Bool {
    !isOneShot && tempo != nil && (beats ?? 1) > 0
  }

  /// The key, when both tonic and mode are known.
  public var key: KeySignature? {
    guard let keyTonic, let keyMode else { return nil }
    return KeySignature(tonic: keyTonic, mode: keyMode)
  }
}

/// Random access to a file's bytes, so metadata can be read from files and, in tests, data.
public protocol MetadataByteSource {
  var byteCount: UInt64 { get }
  func bytes(at offset: UInt64, count: Int) throws -> [UInt8]
}

extension Data: MetadataByteSource {
  public var byteCount: UInt64 { UInt64(count) }

  public func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
    guard offset <= UInt64(self.count) else { return [] }
    let start = startIndex + Int(offset)
    return [UInt8](self[start..<Swift.min(endIndex, start + count)])
  }
}

/// A file read with seeks, so only the chunks that matter are loaded.
public final class FileByteSource: MetadataByteSource {
  private let handle: FileHandle
  public let byteCount: UInt64

  public init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    byteCount = try handle.seekToEnd()
  }

  deinit {
    try? handle.close()
  }

  public func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
    try handle.seek(toOffset: offset)
    return [UInt8](try handle.read(upToCount: count) ?? Data())
  }
}

extension AudioFileMetadata {
  public enum ReadError: Error {
    case unrecognized
  }

  /// The Apple Loops metadata chunk in CAF files: a `uuid` chunk with this ID.
  static let appleLoopsUUID: [UInt8] = [
    0x29, 0x81, 0x92, 0x73, 0xB5, 0xBF, 0x4A, 0xEF, 0xB7, 0x8D, 0x62, 0xD1, 0xEF, 0x90, 0xBB, 0x2C,
  ]
  /// Tag chunks larger than this aren't loops' tags; they're skipped.
  static let maximumTagChunk = 256 * 1024
  static let maximumMIDIChunk = 8 * 1024 * 1024

  /// Reads a CAF, AIFF or WAV file's metadata, then fills in what its name says. Other
  /// formats (MP3, AAC, FLAC) get what the name says only.
  public static func read(_ url: URL, includingMIDI: Bool = false) throws -> AudioFileMetadata {
    var metadata = (try? read(FileByteSource(url: url), includingMIDI: includingMIDI)) ?? AudioFileMetadata()
    metadata.guessFromName(url.deletingPathExtension().lastPathComponent)
    return metadata
  }

  public static func read(_ source: some MetadataByteSource, includingMIDI: Bool = false) throws -> AudioFileMetadata {
    let header = try source.bytes(at: 0, count: 12)
    guard header.count >= 12 else { throw ReadError.unrecognized }
    switch (tag(header, 0), tag(header, 8)) {
    case ("caff", _): return try readCAF(source, includingMIDI: includingMIDI)
    case ("FORM", "AIFF"), ("FORM", "AIFC"): return try readAIFF(source)
    case ("RIFF", "WAVE"): return try readWAV(source)
    default: throw ReadError.unrecognized
    }
  }

  // MARK: - CAF

  private static func readCAF(_ source: some MetadataByteSource, includingMIDI: Bool) throws -> AudioFileMetadata {
    var metadata = AudioFileMetadata()
    var bytesPerPacket: UInt32 = 0
    var framesPerPacket: UInt32 = 0
    var validFrames: Int64?
    var dataBytes: Int64?
    var offset: UInt64 = 8
    while offset + 12 <= source.byteCount {
      let chunkHeader = try source.bytes(at: offset, count: 12)
      guard chunkHeader.count == 12 else { break }
      let type = tag(chunkHeader, 0)
      let declared = Int64(bitPattern: bigEndian(chunkHeader, 4, 8))
      let bodyStart = offset + 12
      // A data chunk of size -1 runs to the end of the file.
      let size = declared < 0 ? Int64(source.byteCount - bodyStart) : declared
      switch type {
      case "desc":
        let body = try source.bytes(at: bodyStart, count: 32)
        guard body.count == 32 else { break }
        metadata.sampleRate = Double(bitPattern: bigEndian(body, 0, 8))
        bytesPerPacket = UInt32(bigEndian(body, 16, 4))
        framesPerPacket = UInt32(bigEndian(body, 20, 4))
      case "pakt":
        let body = try source.bytes(at: bodyStart, count: 16)
        if body.count == 16 { validFrames = Int64(bitPattern: bigEndian(body, 8, 8)) }
      case "data":
        // The first four bytes are an edit count.
        dataBytes = size - 4
      case "info" where size <= maximumTagChunk:
        let pairs = stringPairs(try source.bytes(at: bodyStart + 4, count: Int(size) - 4))
        metadata.apply(appleLoopTags: pairs, overwrite: false)
      case "uuid" where size >= 20 && size <= maximumTagChunk:
        let body = try source.bytes(at: bodyStart, count: Int(size))
        if Array(body.prefix(16)) == appleLoopsUUID {
          metadata.apply(appleLoopTags: stringPairs(Array(body.dropFirst(20))), overwrite: true)
        }
      case "midi":
        metadata.hasMIDI = true
        if includingMIDI, size <= maximumMIDIChunk {
          metadata.midi = Data(try source.bytes(at: bodyStart, count: Int(size)))
        }
      default:
        break
      }
      guard declared >= 0 else { break }
      offset = bodyStart + UInt64(size)
    }
    if let validFrames, validFrames > 0 {
      metadata.frameCount = validFrames
    } else if let dataBytes, bytesPerPacket > 0, framesPerPacket > 0 {
      metadata.frameCount = dataBytes / Int64(bytesPerPacket) * Int64(framesPerPacket)
    }
    return metadata
  }

  /// Apple Loops tags: "beat count", "key signature", "key type", "time signature",
  /// "category", "subcategory", "genre" and "descriptors" (comma-separated). The CAF `info`
  /// chunk uses some of the same keys, and also "tempo".
  mutating func apply(appleLoopTags pairs: [(String, String)], overwrite: Bool) {
    func set<Value>(_ keyPath: WritableKeyPath<AudioFileMetadata, Value?>, _ value: Value?) {
      guard let value, overwrite || self[keyPath: keyPath] == nil else { return }
      self[keyPath: keyPath] = value
    }
    for (key, value) in pairs {
      let value = value.trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { continue }
      switch key.lowercased() {
      case "beat count": set(\.beats, Int(value))
      case "tempo": set(\.statedTempo, Double(value))
      case "key signature": set(\.keyTonic, Self.pitchClass(named: value))
      case "key type":
        switch value.lowercased() {
        case "major": keyMode = .major
        case "minor": keyMode = .minor
        default: break
        }
      case "time signature":
        let parts = value.split(separator: "/").compactMap { Int($0) }
        if parts.count == 2, TimeSignature.supportedBeatUnits.contains(parts[1]), parts[0] > 0 {
          set(\.timeSignature, TimeSignature(beatsPerBar: parts[0], beatUnit: parts[1]))
        }
      case "category": set(\.category, value)
      case "subcategory": set(\.subcategory, value)
      case "genre": set(\.genre, value)
      case "descriptors":
        if overwrite || descriptors.isEmpty {
          descriptors = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
      default: break
      }
    }
  }

  // MARK: - AIFF

  private static func readAIFF(_ source: some MetadataByteSource) throws -> AudioFileMetadata {
    var metadata = AudioFileMetadata()
    var offset: UInt64 = 12
    while offset + 8 <= source.byteCount {
      let chunkHeader = try source.bytes(at: offset, count: 8)
      guard chunkHeader.count == 8 else { break }
      let type = tag(chunkHeader, 0)
      let size = bigEndian(chunkHeader, 4, 4)
      let bodyStart = offset + 8
      switch type {
      case "COMM":
        let body = try source.bytes(at: bodyStart, count: 18)
        guard body.count == 18 else { break }
        metadata.frameCount = Int64(bigEndian(body, 2, 4))
        metadata.sampleRate = extended80(Array(body[8..<18]))
      case "basc":
        // Apple Loops' basic chunk: version, beats, root note, scale type, meter, loop type.
        let body = try source.bytes(at: bodyStart, count: 18)
        guard body.count == 18 else { break }
        metadata.beats = Int(bigEndian(body, 4, 4))
        // Scale types: 1 minor, 2 major, 3 neither (untuned, such as drums, whose root means
        // nothing), 4 both.
        let scale = bigEndian(body, 10, 2)
        if scale == 1 || scale == 2 || scale == 4 { metadata.keyTonic = Int(bigEndian(body, 8, 2)) % 12 }
        if scale == 1 { metadata.keyMode = .minor }
        if scale == 2 { metadata.keyMode = .major }
        let numerator = Int(bigEndian(body, 12, 2))
        let denominator = Int(bigEndian(body, 14, 2))
        if numerator > 0, TimeSignature.supportedBeatUnits.contains(denominator) {
          metadata.timeSignature = TimeSignature(beatsPerBar: numerator, beatUnit: denominator)
        }
        metadata.isOneShot = bigEndian(body, 16, 2) == 1
      default:
        break
      }
      offset = bodyStart + UInt64(size) + UInt64(size & 1)
    }
    return metadata
  }

  /// An 80-bit IEEE extended float, as AIFF stores its sample rate.
  static func extended80(_ bytes: [UInt8]) -> Double? {
    guard bytes.count == 10 else { return nil }
    let exponent = Int(bigEndian(bytes, 0, 2) & 0x7FFF) - 16383
    let mantissa = bigEndian(bytes, 2, 8)
    guard mantissa != 0 else { return 0 }
    return Double(mantissa) * pow(2, Double(exponent - 63))
  }

  // MARK: - WAV

  private static func readWAV(_ source: some MetadataByteSource) throws -> AudioFileMetadata {
    var metadata = AudioFileMetadata()
    var blockAlign: UInt64 = 0
    var dataBytes: UInt64?
    var offset: UInt64 = 12
    while offset + 8 <= source.byteCount {
      let chunkHeader = try source.bytes(at: offset, count: 8)
      guard chunkHeader.count == 8 else { break }
      let type = tag(chunkHeader, 0)
      let size = littleEndian(chunkHeader, 4, 4)
      let bodyStart = offset + 8
      switch type {
      case "fmt ":
        let body = try source.bytes(at: bodyStart, count: 16)
        guard body.count == 16 else { break }
        metadata.sampleRate = Double(littleEndian(body, 4, 4))
        blockAlign = littleEndian(body, 12, 2)
      case "data":
        dataBytes = min(size, source.byteCount - bodyStart)
      case "acid":
        // ACID: flags, root note, two unused fields, beats, meter (denominator first), tempo.
        let body = try source.bytes(at: bodyStart, count: 24)
        guard body.count == 24 else { break }
        let flags = littleEndian(body, 0, 4)
        metadata.isOneShot = flags & 0x01 != 0
        if flags & 0x02 != 0 { metadata.keyTonic = Int(littleEndian(body, 4, 2)) % 12 }
        let beats = Int(littleEndian(body, 12, 4))
        if beats > 0 { metadata.beats = beats }
        let denominator = Int(littleEndian(body, 16, 2))
        let numerator = Int(littleEndian(body, 18, 2))
        if numerator > 0, TimeSignature.supportedBeatUnits.contains(denominator) {
          metadata.timeSignature = TimeSignature(beatsPerBar: numerator, beatUnit: denominator)
        }
        let tempo = Double(Float(bitPattern: UInt32(littleEndian(body, 20, 4))))
        if tempo.isFinite, tempo > 0 { metadata.statedTempo = tempo }
      case "LIST" where size <= UInt64(maximumTagChunk):
        let body = try source.bytes(at: bodyStart, count: Int(size))
        if body.count >= 4, tag(body, 0) == "INFO" { metadata.applyInfoList(Array(body.dropFirst(4))) }
      default:
        break
      }
      offset = bodyStart + size + (size & 1)
    }
    if let dataBytes, blockAlign > 0 { metadata.frameCount = Int64(dataBytes / blockAlign) }
    return metadata
  }

  /// A WAV file's `INFO` list: genre (`IGNR`) and keywords (`IKEY`).
  private mutating func applyInfoList(_ bytes: [UInt8]) {
    var index = 0
    while index + 8 <= bytes.count {
      let id = Self.tag(bytes, index)
      let size = Int(Self.littleEndian(bytes, index + 4, 4))
      let start = index + 8
      guard start + size <= bytes.count else { break }
      let text = String(decoding: bytes[start..<(start + size)].prefix { $0 != 0 }, as: UTF8.self)
        .trimmingCharacters(in: .whitespaces)
      if !text.isEmpty {
        switch id {
        case "IGNR": if genre == nil { genre = text }
        case "IKEY":
          if descriptors.isEmpty {
            descriptors = text.split { $0 == ";" || $0 == "," }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
          }
        default: break
        }
      }
      index = start + size + (size & 1)
    }
  }

  // MARK: - Names

  /// Fills in a tempo and key the file's name states, where its tags don't: “124 BPM”,
  /// “124bpm”, and keys with a mode such as “Am”, “C#min”, “F♯ minor” or “Ebmaj”.
  public mutating func guessFromName(_ name: String) {
    let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
      .split(separator: " ").map(String.init)
    if tempo == nil {
      for (index, word) in words.enumerated() {
        let lower = word.lowercased()
        var number: Double?
        if lower.hasSuffix("bpm") {
          number = Double(lower.dropLast(3))
          if number == nil, lower == "bpm", index > 0 { number = Double(words[index - 1]) }
        }
        if let number, (40...300).contains(number) {
          statedTempo = number
          break
        }
      }
    }
    if keyTonic == nil {
      for (index, word) in words.enumerated() {
        let next = index + 1 < words.count ? words[index + 1].lowercased() : nil
        if let (tonic, mode) = Self.key(inWord: word, next: next) {
          keyTonic = tonic
          keyMode = mode
          break
        }
      }
    }
    // With a tempo but no beat count, count beats from the length, if it's close to whole.
    if beats == nil, !isOneShot, let statedTempo, let duration {
      let counted = duration * statedTempo / 60
      if counted >= 1, abs(counted - counted.rounded()) < 0.05 { beats = Int(counted.rounded()) }
    }
  }

  /// A key in one word of a name (“Am”, “C#min”, “Ebmajor”) or a note followed by a mode
  /// word (“F# minor”). Bare note letters aren't keys: too many words start with them.
  static func key(inWord word: String, next: String?) -> (Int, KeySignature.Mode)? {
    let modes: [(String, KeySignature.Mode)] = [
      ("minor", .minor), ("major", .major), ("min", .minor), ("maj", .major), ("m", .minor),
    ]
    for (suffix, mode) in modes {
      guard word.lowercased().hasSuffix(suffix), word.count > suffix.count else { continue }
      let note = String(word.dropLast(suffix.count))
      // "m" must follow a capital note letter: "Am", not "am" or "Drum".
      if suffix == "m", !(note.first?.isUppercase ?? false) { continue }
      if let tonic = pitchClass(named: note) { return (tonic, mode) }
    }
    if let next, let tonic = pitchClass(named: word), word.first?.isUppercase == true {
      switch next {
      case "minor", "min": return (tonic, .minor)
      case "major", "maj": return (tonic, .major)
      default: break
      }
    }
    return nil
  }

  /// The pitch class of a note name: "C", "F#", "F♯", "Bb", "B♭" (any case).
  static func pitchClass(named name: String) -> Int? {
    let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    guard let first = name.uppercased().first, let base = letters[first] else { return nil }
    let accidental = name.dropFirst()
    switch accidental {
    case "": return base
    case "#", "♯": return (base + 1) % 12
    case "b", "♭": return (base + 11) % 12
    default: return nil
    }
  }

  // MARK: - Bytes

  static func tag(_ bytes: [UInt8], _ offset: Int) -> String {
    guard offset + 4 <= bytes.count else { return "" }
    return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
  }

  static func bigEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
    guard offset + count <= bytes.count else { return 0 }
    return bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | UInt64($1) }
  }

  static func littleEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
    guard offset + count <= bytes.count else { return 0 }
    return bytes[offset..<(offset + count)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
  }

  /// Null-terminated key and value strings, one after another.
  static func stringPairs(_ bytes: [UInt8]) -> [(String, String)] {
    let strings = bytes.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    return stride(from: 0, to: strings.count - 1, by: 2).map { (strings[$0], strings[$0 + 1]) }
  }
}
