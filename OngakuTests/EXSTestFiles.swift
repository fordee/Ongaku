//
//  EXSTestFiles.swift
//  OngakuTests
//

import AVFAudio
import Foundation

/// Builds small EXS instruments and tone files for tests, in the layout Logic writes: an
/// instrument chunk counting the others, then zones, groups and samples.
enum EXSTestFiles {
  struct Zone {
    var root: Int
    var keys: ClosedRange<Int>
    var sampleStart = 0
    var sampleEnd: Int
    var sample = 0
    var group = 0
    /// 108 is the classic zone; newer Logic versions write up to 148 bytes.
    var size = 108
  }

  struct Group {
    var velocities: ClosedRange<Int> = 0...127
    /// In decibels.
    var volume = 0
  }

  struct Sample {
    var folder: String
    var file: String
    var frames: Int
    var sampleRate = 44100
    /// The file type as Logic records it, four characters reversed ("ffac" for CAF), if any.
    var typeCode: String?
    var channels = 1
  }

  static func littleEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
  }

  static func field(_ text: String, _ count: Int) -> [UInt8] {
    Array(text.utf8.prefix(count - 1)) + [UInt8](repeating: 0, count: count - min(count - 1, text.utf8.count))
  }

  /// Newer EXS files (Logic 10.5 on) set 0x40 in each chunk's type byte.
  nonisolated(unsafe) static var newerFormat = false

  static func chunk(_ type: UInt64, index: Int, name: String, _ body: [UInt8]) -> [UInt8] {
    littleEndian(0x0000_0101 | (type | (newerFormat ? 0x40 : 0)) << 24, 4) + littleEndian(UInt64(body.count), 4) + littleEndian(UInt64(index), 4)
      + littleEndian(0, 4) + Array("TBOS".utf8) + field(name, 64) + body
  }

  static func instrument(
    name: String, zones: [Zone], groups: [Group] = [Group()], samples: [Sample], extraChunks: [(type: UInt64, body: [UInt8])] = []
  ) -> Data {
    var bytes = chunk(0, index: 0, name: name,
      littleEndian(0, 4) + littleEndian(UInt64(zones.count), 4) + littleEndian(UInt64(groups.count), 4) + littleEndian(UInt64(samples.count), 4)
        + [UInt8](repeating: 0, count: 24))
    for (index, zone) in zones.enumerated() {
      var body = [UInt8](repeating: 0, count: zone.size)
      body[1] = UInt8(zone.root)
      body[6] = UInt8(zone.keys.lowerBound)
      body[7] = UInt8(zone.keys.upperBound)
      body[10] = 127
      body.replaceSubrange(12..<16, with: littleEndian(UInt64(zone.sampleStart), 4))
      body.replaceSubrange(16..<20, with: littleEndian(UInt64(zone.sampleEnd), 4))
      body.replaceSubrange(88..<92, with: littleEndian(UInt64(zone.group), 4))
      body.replaceSubrange(92..<96, with: littleEndian(UInt64(zone.sample), 4))
      // Newer Logic fills in fields after the classic ones, such as these at 116 and 120
      // (positions in the sample file), which Apple's sampler won't accept.
      if zone.size >= 124 {
        body.replaceSubrange(116..<120, with: littleEndian(UInt64(zone.sampleEnd + 1024), 4))
        body.replaceSubrange(120..<124, with: littleEndian(UInt64(zone.sampleEnd * 4), 4))
      }
      bytes += chunk(1, index: index, name: "Zone \(index + 1)", body)
    }
    // Groups of every key, played whatever the tempo.
    for (index, group) in groups.enumerated() {
      var body = [UInt8](repeating: 0, count: 168)
      body[0] = UInt8(bitPattern: Int8(group.volume))
      body[5] = UInt8(group.velocities.lowerBound)
      body[6] = UInt8(group.velocities.upperBound)
      body[38] = 80
      body[39] = 140
      body[89] = 127
      bytes += chunk(2, index: index, name: "Group \(index + 1)", body)
    }
    for (index, sample) in samples.enumerated() {
      var format = [UInt8](repeating: 0, count: 80)
      format.replaceSubrange(4..<8, with: littleEndian(UInt64(sample.frames), 4))
      format.replaceSubrange(8..<12, with: littleEndian(UInt64(sample.sampleRate), 4))
      format.replaceSubrange(12..<16, with: littleEndian(16, 4))
      format.replaceSubrange(16..<20, with: littleEndian(UInt64(sample.channels), 4))
      format.replaceSubrange(20..<24, with: littleEndian(UInt64(sample.channels), 4))
      if let code = sample.typeCode { format.replaceSubrange(28..<32, with: Array(code.utf8)) }
      bytes += chunk(3, index: index, name: sample.file, format + field(sample.folder, 256) + field(sample.file, 256))
    }
    for extra in extraChunks {
      bytes += chunk(extra.type, index: 0, name: "Extra", extra.body)
    }
    return Data(bytes)
  }

  /// A mono 16-bit file of sine tones, one after another (frequency, frames).
  static func writeTones(_ segments: [(Double, Int)], to url: URL, bigEndian: Bool = false, sampleRate: Double = 44100) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let total = segments.reduce(0) { $0 + $1.1 }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
    buffer.frameLength = AVAudioFrameCount(total)
    var index = 0
    for (frequency, frames) in segments {
      for frame in 0..<frames {
        buffer.floatChannelData![0][index] = 0.5 * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        index += 1
      }
    }
    try file.write(from: buffer)
  }
}
