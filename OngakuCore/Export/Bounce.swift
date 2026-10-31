//
//  Bounce.swift
//  OngakuCore
//

import Foundation

/// How a mix is bounced to an audio file, as chosen in the Bounce dialog.
public struct BounceSettings: Codable, Sendable, Equatable {
  public enum FileFormat: String, CaseIterable, Codable, Sendable {
    case wav, aiff, m4a

    public var name: String {
      switch self {
      case .wav: "WAVE"
      case .aiff: "AIFF"
      case .m4a: "AAC (M4A)"
      }
    }

    public var fileExtension: String { rawValue }

    /// The bit depths this format can store; empty for compressed formats.
    public var bitDepths: [BitDepth] {
      switch self {
      case .wav: BitDepth.allCases
      case .aiff: [.sixteen, .twentyFour]
      case .m4a: []
      }
    }

    /// The sample rates this format can store. AAC goes up to 48 kHz.
    public var sampleRates: [Double] {
      self == .m4a ? [44_100, 48_000] : [44_100, 48_000, 88_200, 96_000]
    }
  }

  public enum BitDepth: Int, CaseIterable, Codable, Sendable {
    case sixteen = 16
    case twentyFour = 24
    case thirtyTwoFloat = 32

    public var name: String {
      self == .thirtyTwoFloat ? "32-bit Float" : "\(rawValue)-bit"
    }
  }

  /// AAC files are encoded at this bit rate, in bits per second.
  public static let aacBitRate = 256_000

  public var format: FileFormat
  public var bitDepth: BitDepth
  public var sampleRate: Double
  /// Scale the whole bounce so its loudest peak sits just below full scale.
  public var normalize: Bool
  /// Keep rendering after the end until reverb and delay tails have died away.
  public var includeTail: Bool

  public init(
    format: FileFormat = .wav, bitDepth: BitDepth = .twentyFour, sampleRate: Double = 48_000,
    normalize: Bool = false, includeTail: Bool = true
  ) {
    self.format = format
    self.bitDepth = bitDepth
    self.sampleRate = sampleRate
    self.normalize = normalize
    self.includeTail = includeTail
  }

  /// The bit depth actually written: the chosen one if the format supports it, otherwise
  /// the deepest it does, and `nil` for compressed formats.
  public var effectiveBitDepth: BitDepth? {
    let supported = format.bitDepths
    return supported.contains(bitDepth) ? bitDepth : supported.last
  }

  /// The sample rate actually rendered: the chosen one, or the nearest the format supports.
  public var effectiveSampleRate: Double {
    let supported = format.sampleRates
    return supported.contains(sampleRate) ? sampleRate : supported.min { abs($0 - sampleRate) < abs($1 - sampleRate) } ?? 48_000
  }

  /// 16-bit files get dither, so quiet passages fade out smoothly instead of turning into
  /// distortion as they approach the last bit.
  public var usesDither: Bool { effectiveBitDepth == .sixteen }

  /// Where normalizing puts the loudest peak, in dBFS. AAC leaves more headroom because
  /// encoding can push peaks above the original.
  public var normalizationTarget: Double {
    format == .m4a ? -1 : -0.1
  }

  /// The gain that brings `peak` (linear, 1 = full scale) to the normalization target, or 1
  /// for silence.
  public func normalizationGain(forPeak peak: Float) -> Float {
    guard peak > 0 else { return 1 }
    return Float(pow(10, normalizationTarget / 20)) / peak
  }
}

extension Project {
  /// What Bounce renders: the cycle range when cycle is on (as in Logic), otherwise from the
  /// start of the project to the end of its last region. `nil` when there is nothing to bounce.
  public var bounceRange: Range<Tick>? {
    if cycle.isEnabled, cycle.length > .zero {
      return cycle.start..<cycle.end
    }
    let lastEnd = tracks.flatMap { $0.playedRegions(until: endPosition) }.map(\.end).max()
    guard let lastEnd, lastEnd > .zero else { return nil }
    return .zero..<lastEnd
  }

  /// A copy that plays `range` once, start to finish: cycle off and the end at the range end.
  public func playingOnce(_ range: Range<Tick>) -> Project {
    var project = self
    project.cycle.isEnabled = false
    project.endPosition = range.upperBound
    return project
  }
}
