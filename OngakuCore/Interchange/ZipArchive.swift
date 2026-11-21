//
//  ZipArchive.swift
//  OngakuCore
//

import Compression
import Foundation

/// Just enough ZIP for DAWproject files: writing stored (uncompressed) entries, and reading
/// stored or deflated ones, as other apps write them.
public enum ZipArchive {
  public enum ZipError: LocalizedError {
    case notAZip
    case unsupported(String)
    case corrupt(String)

    public var errorDescription: String? {
      switch self {
      case .notAZip: "The file isn't a ZIP archive."
      case .unsupported(let what): "The archive uses \(what), which Ongaku Studio can't read."
      case .corrupt(let name): "“\(name)” in the archive is damaged."
      }
    }
  }

  /// One file in an archive.
  public struct Entry: Sendable {
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
      self.path = path
      self.data = data
    }
  }

  // MARK: - Writing

  /// Writes entries to a ZIP file, uncompressed (audio doesn't shrink much anyway).
  public static func write(_ entries: [Entry], to url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var central = Data()
    var offset: UInt32 = 0
    for entry in entries {
      let name = Data(entry.path.utf8)
      let crc = crc32(entry.data)
      guard entry.data.count < Int(UInt32.max), offset < UInt32.max - UInt32(entry.data.count) else {
        throw ZipError.unsupported("files over 4 GB")
      }
      let size = UInt32(entry.data.count)
      var local = Data()
      local.append(le32: 0x0403_4B50)
      local.append(le16: 20)  // version needed
      local.append(le16: 0x0800)  // UTF-8 names
      local.append(le16: 0)  // stored
      local.append(le16: 0)
      local.append(le16: 0x21)  // 1980-01-01
      local.append(le32: crc)
      local.append(le32: size)
      local.append(le32: size)
      local.append(le16: UInt16(name.count))
      local.append(le16: 0)
      local.append(name)
      try handle.write(contentsOf: local)
      try handle.write(contentsOf: entry.data)

      central.append(le32: 0x0201_4B50)
      central.append(le16: 20)
      central.append(le16: 20)
      central.append(le16: 0x0800)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0x21)
      central.append(le32: crc)
      central.append(le32: size)
      central.append(le32: size)
      central.append(le16: UInt16(name.count))
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le32: 0)
      central.append(le32: offset)
      central.append(name)
      offset += UInt32(local.count) + size
    }
    var end = Data()
    end.append(le32: 0x0605_4B50)
    end.append(le16: 0)
    end.append(le16: 0)
    end.append(le16: UInt16(entries.count))
    end.append(le16: UInt16(entries.count))
    end.append(le32: UInt32(central.count))
    end.append(le32: offset)
    end.append(le16: 0)
    try handle.write(contentsOf: central)
    try handle.write(contentsOf: end)
  }

  // MARK: - Reading

  /// Every file in an archive (folders left out).
  public static func read(_ data: Data) throws -> [Entry] {
    let bytes = [UInt8](data)
    // The end of the central directory: its signature, searched for from the end.
    guard bytes.count >= 22 else { throw ZipError.notAZip }
    var endIndex: Int?
    for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1)
    where bytes.le32(at: index) == 0x0605_4B50 {
      endIndex = index
      break
    }
    guard let end = endIndex else { throw ZipError.notAZip }
    let count = Int(bytes.le16(at: end + 10))
    var position = Int(bytes.le32(at: end + 16))
    if bytes.le32(at: end + 16) == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
    var entries: [Entry] = []
    for _ in 0..<count {
      guard position + 46 <= bytes.count, bytes.le32(at: position) == 0x0201_4B50 else { throw ZipError.corrupt("directory") }
      let method = bytes.le16(at: position + 10)
      let compressedSize = Int(bytes.le32(at: position + 20))
      let size = Int(bytes.le32(at: position + 24))
      let nameLength = Int(bytes.le16(at: position + 28))
      let extraLength = Int(bytes.le16(at: position + 30))
      let commentLength = Int(bytes.le16(at: position + 32))
      let localOffset = Int(bytes.le32(at: position + 42))
      let name = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
      position += 46 + nameLength + extraLength + commentLength
      guard !name.hasSuffix("/") else { continue }
      guard localOffset + 30 <= bytes.count, bytes.le32(at: localOffset) == 0x0403_4B50 else { throw ZipError.corrupt(name) }
      let dataStart = localOffset + 30 + Int(bytes.le16(at: localOffset + 26)) + Int(bytes.le16(at: localOffset + 28))
      guard dataStart + compressedSize <= bytes.count else { throw ZipError.corrupt(name) }
      let stored = data.subdata(in: dataStart..<(dataStart + compressedSize))
      switch method {
      case 0: entries.append(Entry(path: name, data: stored))
      case 8: entries.append(Entry(path: name, data: try inflate(stored, size: size, name: name)))
      default: throw ZipError.unsupported("compression method \(method)")
      }
    }
    return entries
  }

  /// Raw deflate, as ZIP stores it.
  static func inflate(_ data: Data, size: Int, name: String) throws -> Data {
    guard size > 0 else { return Data() }
    var output = Data(count: size)
    let written = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, size,
          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw ZipError.corrupt(name) }
    return output
  }

  // MARK: - CRC-32

  private static let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }

  static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { buffer in
      for byte in buffer { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
    return crc ^ 0xFFFF_FFFF
  }
}

extension Data {
  mutating func append(le16 value: UInt16) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  mutating func append(le32 value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}

extension [UInt8] {
  func le16(at index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }

  func le32(at index: Int) -> UInt32 {
    UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
  }
}
