//
//  SamplerInstrument.swift
//  OngakuCore
//

import Foundation

/// A sampler instrument from a sound library, played by Apple's sampler: an EXS instrument,
/// an Audio Unit sampler preset, or one preset of a SoundFont or DLS bank.
///
/// It's found by library and path rather than by where the file was, so a song still finds
/// its instruments when a library moves, or on another Mac with the same library added.
public struct SamplerInstrument: Codable, Sendable, Hashable {
  /// The library it came from, and its name for messages when that library isn't there.
  public var libraryID: UUID?
  public var libraryName: String
  /// From the library's folder, with "/" between folders.
  public var path: String
  /// A SoundFont or DLS bank's preset; `nil` for EXS instruments and presets.
  public var preset: SoundBankPreset?

  public init(libraryID: UUID?, libraryName: String, path: String, preset: SoundBankPreset? = nil) {
    self.libraryID = libraryID
    self.libraryName = libraryName
    self.path = path
    self.preset = preset
  }

  /// The preset's name, or the file's without its extension.
  public var name: String {
    if let preset { return preset.name }
    let fileName = path.split(separator: "/").last.map(String.init) ?? path
    return (fileName as NSString).deletingPathExtension
  }

  public var fileExtension: String {
    (path as NSString).pathExtension.lowercased()
  }

  /// Formats Apple's sampler plays (SFZ through a preset made from it).
  public static let playableExtensions: Set<String> = ["exs", "sf2", "dls", "aupreset", "sfz"]

  /// Whether Ongaku can play the file's format.
  public static func isPlayable(_ path: String) -> Bool {
    playableExtensions.contains((path as NSString).pathExtension.lowercased())
  }
}

/// One instrument in a SoundFont (`.sf2`) or DLS bank.
public struct SoundBankPreset: Codable, Sendable, Hashable {
  public var name: String
  /// The MIDI program, 0–127.
  public var program: Int
  /// The bank: SoundFonts number drum kits 128; DLS banks mark them with `isPercussion`.
  public var bank: Int
  public var isPercussion: Bool

  public init(name: String, program: Int, bank: Int, isPercussion: Bool) {
    self.name = name
    self.program = program
    self.bank = bank
    self.isPercussion = isPercussion
  }
}

/// Lists the presets in SoundFont and DLS banks, from their RIFF chunks.
public enum SoundBankReader {
  /// The presets in a bank file, sorted by bank and program; empty if it can't be read.
  public static func presets(in url: URL) -> [SoundBankPreset] {
    guard let source = try? FileByteSource(url: url) else { return [] }
    return (try? presets(in: source)) ?? []
  }

  public static func presets(in source: some MetadataByteSource) throws -> [SoundBankPreset] {
    let header = try source.bytes(at: 0, count: 12)
    guard header.count == 12, AudioFileMetadata.tag(header, 0) == "RIFF" else { return [] }
    var presets: [SoundBankPreset]
    switch AudioFileMetadata.tag(header, 8) {
    case "sfbk": presets = try soundFontPresets(source)
    case "DLS ": presets = try dlsPresets(source)
    default: return []
    }
    presets.sort { ($0.isPercussion ? 1 : 0, $0.bank, $0.program) < ($1.isPercussion ? 1 : 0, $1.bank, $1.program) }
    return presets
  }

  /// The chunks in a RIFF list from `start` to `end`: their IDs, where their bodies start,
  /// and their sizes.
  private static func chunks(_ source: some MetadataByteSource, from start: UInt64, to end: UInt64) throws
    -> [(id: String, body: UInt64, size: UInt64)]
  {
    var result: [(String, UInt64, UInt64)] = []
    var offset = start
    while offset + 8 <= end {
      let header = try source.bytes(at: offset, count: 8)
      guard header.count == 8 else { break }
      let size = AudioFileMetadata.littleEndian(header, 4, 4)
      result.append((AudioFileMetadata.tag(header, 0), offset + 8, size))
      offset += 8 + size + (size & 1)
    }
    return result
  }

  /// A `LIST` chunk's type ("pdta", "lins") and the range of its contents.
  private static func list(_ source: some MetadataByteSource, _ chunk: (id: String, body: UInt64, size: UInt64)) throws -> (type: String, start: UInt64, end: UInt64)? {
    guard chunk.id == "LIST", chunk.size >= 4 else { return nil }
    let type = AudioFileMetadata.tag(try source.bytes(at: chunk.body, count: 4), 0)
    return (type, chunk.body + 4, chunk.body + chunk.size)
  }

  /// SoundFont 2: the `phdr` records in the `pdta` list, 38 bytes each (name, preset, bank,
  /// …), the last being the "EOP" terminator.
  private static func soundFontPresets(_ source: some MetadataByteSource) throws -> [SoundBankPreset] {
    for chunk in try chunks(source, from: 12, to: source.byteCount) {
      guard let list = try list(source, chunk), list.type == "pdta" else { continue }
      for inner in try chunks(source, from: list.start, to: list.end) where inner.id == "phdr" {
        let bytes = try source.bytes(at: inner.body, count: Int(min(inner.size, 38 * 4096)))
        let count = bytes.count / 38
        return (0..<max(0, count - 1)).map { index in
          let record = Array(bytes[(index * 38)..<(index * 38 + 38)])
          let bank = Int(AudioFileMetadata.littleEndian(record, 22, 2))
          return SoundBankPreset(
            name: cString(record[0..<20]), program: Int(AudioFileMetadata.littleEndian(record, 20, 2)) & 0x7F,
            bank: bank, isPercussion: bank == 128)
        }
      }
    }
    return []
  }

  /// DLS: each `ins ` list in `lins` has an `insh` header (regions, bank, instrument) and an
  /// `INFO` list whose `INAM` is its name. Bit 31 of the bank marks drum kits.
  private static func dlsPresets(_ source: some MetadataByteSource) throws -> [SoundBankPreset] {
    var presets: [SoundBankPreset] = []
    for chunk in try chunks(source, from: 12, to: source.byteCount) {
      guard let instruments = try list(source, chunk), instruments.type == "lins" else { continue }
      for instrumentChunk in try chunks(source, from: instruments.start, to: instruments.end) {
        guard let instrument = try list(source, instrumentChunk), instrument.type == "ins " else { continue }
        var name = ""
        var locale: (bank: UInt64, program: UInt64)?
        for part in try chunks(source, from: instrument.start, to: instrument.end) {
          if part.id == "insh" {
            let header = try source.bytes(at: part.body, count: 12)
            if header.count == 12 {
              locale = (AudioFileMetadata.littleEndian(header, 4, 4), AudioFileMetadata.littleEndian(header, 8, 4))
            }
          } else if let info = try list(source, part), info.type == "INFO" {
            for field in try chunks(source, from: info.start, to: info.end) where field.id == "INAM" {
              name = cString(try source.bytes(at: field.body, count: Int(min(field.size, 256)))[...])
            }
          }
        }
        guard let locale else { continue }
        let bankNumber = Int(((locale.bank >> 8) & 0x7F) << 7 | (locale.bank & 0x7F))
        presets.append(SoundBankPreset(
          name: name.isEmpty ? "Instrument \(locale.program + 1)" : name, program: Int(locale.program & 0x7F),
          bank: bankNumber, isPercussion: locale.bank & 0x8000_0000 != 0))
      }
    }
    return presets
  }

  private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }
}
