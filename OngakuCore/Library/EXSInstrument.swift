//
//  EXSInstrument.swift
//  OngakuCore
//

import Foundation

/// The sample references in an EXS instrument (Logic's Sampler and EXS24 format).
///
/// An EXS file is a list of chunks — header, zones, groups, samples, parameters — each an
/// 84-byte header (signature, size, ID, flags, "TBOS" magic, 64-byte name) and a body. A
/// sample chunk records the folder its audio file was in and the file's name. Those folders
/// are where the library was installed when the instrument was made, so a library that has
/// moved (to another drive, or another Mac) plays only once they're pointed at where the
/// samples are now.
///
/// Newer versions of Logic also write longer zone chunks (up to 148 bytes rather than the
/// classic 108), which Apple's sampler rejects as a format it doesn't support; the classic
/// fields all come first, so a copy with its zones cut back to 108 bytes plays.
///
/// Files come little- or big-endian ("TBOS" or "SOBT" as the magic), and older ones with
/// 0x80 set in each chunk's type byte ("JBOS" and "SOBJ"). Whichever, the type byte is the
/// chunk's fourth.
public struct EXSInstrument: Sendable {
  public struct Sample: Sendable, Equatable {
    /// Where the chunk starts in the file.
    public var chunkOffset: Int
    /// The folder the instrument says the sample is in.
    public var folder: String
    public var fileName: String

    public var path: String {
      folder.hasSuffix("/") ? folder + fileName : folder + "/" + fileName
    }
  }

  static let headerSize = 84
  /// In a zone: options, then (among others) the zone's volume, velocity range and group.
  static let zoneOptionsOffset = 0
  static let zoneVolumeOffset = 4
  static let zoneVelocityOffset = 9
  static let zoneGroupOffset = 88
  /// The zone option that turns its velocity range on.
  static let zoneVelocityRangeOn: UInt8 = 0x08
  /// In a group: its volume, then at 5 and 6 its velocity range.
  static let groupVolumeOffset = 0
  static let groupVelocityOffset = 5
  /// The zone chunk body Apple's sampler reads.
  public static let classicZoneSize = 108
  static let folderOffset = 164
  static let fileNameOffset = 420
  static let fieldSize = 256

  public let data: Data
  public let samples: [Sample]
  /// Where each zone chunk starts, and its body size.
  public let zones: [(offset: Int, size: Int)]
  /// Where each group chunk starts, and its body size.
  public let groups: [(offset: Int, size: Int)]
  private let isBigEndian: Bool

  /// Reads an instrument's sample references; `nil` if it isn't an EXS file.
  public init?(data: Data) {
    let bytes = [UInt8](data)
    guard bytes.count >= Self.headerSize else { return nil }
    switch AudioFileMetadata.tag(bytes, 16) {
    case "TBOS", "JBOS": isBigEndian = false
    case "SOBT", "SOBJ": isBigEndian = true
    default: return nil
    }
    self.data = data
    var samples: [Sample] = []
    var zones: [(offset: Int, size: Int)] = []
    var groups: [(offset: Int, size: Int)] = []
    var offset = 0
    while offset + Self.headerSize <= bytes.count {
      let type = bytes[offset + 3]
      var size = Int(isBigEndian ? AudioFileMetadata.bigEndian(bytes, offset + 4, 4) : AudioFileMetadata.littleEndian(bytes, offset + 4, 4))
      // With 0x80 in the type byte, only the low 15 bits are the size.
      if type & 0x80 != 0 { size &= 0x7FFF }
      guard size >= 0, offset + Self.headerSize + size <= bytes.count else { break }
      if type & 0x0F == 1 { zones.append((offset, size)) }
      if type & 0x0F == 2 { groups.append((offset, size)) }
      if type & 0x0F == 3, offset + Self.folderOffset + Self.fieldSize <= bytes.count {
        let folder = Self.string(bytes, offset + Self.folderOffset, Self.fieldSize)
        // Newer files keep the file name in its own field; older ones only in the chunk name.
        let hasFileNameField = Self.headerSize + size >= Self.fileNameOffset + Self.fieldSize
        let fileName = hasFileNameField ? Self.string(bytes, offset + Self.fileNameOffset, Self.fieldSize) : ""
        samples.append(Sample(chunkOffset: offset, folder: folder, fileName: fileName.isEmpty ? Self.string(bytes, offset + 20, 64) : fileName))
      }
      offset += Self.headerSize + size
    }
    self.samples = samples
    self.zones = zones
    self.groups = groups
  }

  /// Whether Apple's sampler needs a copy with shorter zones.
  public var hasLongZones: Bool {
    zones.contains { $0.size > Self.classicZoneSize }
  }

  /// The instrument as Apple's sampler reads it: zone chunks longer than the classic 108
  /// bytes are cut back to it, their sizes changed to match. `nil` if none are longer.
  public func withClassicZones() -> Data? {
    guard hasLongZones else { return nil }
    let bytes = [UInt8](data)
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var copied = 0
    for zone in zones where zone.size > Self.classicZoneSize {
      let bodyStart = zone.offset + Self.headerSize
      result += bytes[copied..<bodyStart]
      let sizeField = isBigEndian
        ? (0..<4).reversed().map { UInt8(truncatingIfNeeded: Self.classicZoneSize >> (8 * $0)) }
        : (0..<4).map { UInt8(truncatingIfNeeded: Self.classicZoneSize >> (8 * $0)) }
      result.replaceSubrange((result.count - Self.headerSize + 4)..<(result.count - Self.headerSize + 8), with: sizeField)
      result += bytes[bodyStart..<(bodyStart + Self.classicZoneSize)]
      copied = bodyStart + zone.size
    }
    result += bytes[copied...]
    return Data(result)
  }

  /// The instrument with each group's velocity range and volume put on its zones, or `nil`
  /// if none has either. Logic plays a group's zones only at its velocities, and louder or
  /// quieter by its volume; Apple's sampler ignores both. Instruments with a group for each
  /// velocity layer (most of Logic's and GarageBand's) otherwise play every layer at once,
  /// and without the groups' gain.
  public func withGroupSettingsOnZones() -> Data? {
    var bytes = [UInt8](data)
    var changed = false
    for zone in zones where zone.size >= Self.zoneGroupOffset + 4 {
      let body = zone.offset + Self.headerSize
      let index = Int(Int32(truncatingIfNeeded: isBigEndian
        ? AudioFileMetadata.bigEndian(bytes, body + Self.zoneGroupOffset, 4)
        : AudioFileMetadata.littleEndian(bytes, body + Self.zoneGroupOffset, 4)))
      guard groups.indices.contains(index), groups[index].size > Self.groupVelocityOffset + 1 else { continue }
      let group = groups[index].offset + Self.headerSize
      var low = bytes[group + Self.groupVelocityOffset], high = bytes[group + Self.groupVelocityOffset + 1]
      if low > 0 || high < 127 {
        // Within the zone's own range, if it has one; a zone outside its group's never plays,
        // but Apple's sampler has no way to say so, so it's left as it is.
        if bytes[body + Self.zoneOptionsOffset] & Self.zoneVelocityRangeOn != 0 {
          low = max(low, bytes[body + Self.zoneVelocityOffset])
          high = min(high, bytes[body + Self.zoneVelocityOffset + 1])
        }
        if low <= high {
          bytes[body + Self.zoneVelocityOffset] = low
          bytes[body + Self.zoneVelocityOffset + 1] = high
          bytes[body + Self.zoneOptionsOffset] |= Self.zoneVelocityRangeOn
          changed = true
        }
      }
      // Volumes are signed decibels.
      let groupVolume = Int(Int8(bitPattern: bytes[group + Self.groupVolumeOffset]))
      if groupVolume != 0 {
        let zoneVolume = Int(Int8(bitPattern: bytes[body + Self.zoneVolumeOffset]))
        bytes[body + Self.zoneVolumeOffset] = UInt8(bitPattern: Int8(clamping: zoneVolume + groupVolume))
        changed = true
      }
    }
    return changed ? Data(bytes) : nil
  }

  /// The instrument with each sample's folder replaced by what `locate` finds for it (a
  /// folder path), or `nil` if nothing changed. Samples `locate` can't find are left as they
  /// were.
  public func relocatingSamples(_ locate: (Sample) -> String?) -> Data? {
    var bytes = [UInt8](data)
    var changed = false
    for sample in samples {
      guard let folder = locate(sample), folder != sample.folder else { continue }
      var field = Array(folder.utf8)
      guard field.count < Self.fieldSize else { continue }
      field += [UInt8](repeating: 0, count: Self.fieldSize - field.count)
      bytes.replaceSubrange((sample.chunkOffset + Self.folderOffset)..<(sample.chunkOffset + Self.folderOffset + Self.fieldSize), with: field)
      changed = true
    }
    return changed ? Data(bytes) : nil
  }

  private static func string(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
    String(decoding: bytes[offset..<(offset + count)].prefix { $0 != 0 }, as: UTF8.self)
  }
}
