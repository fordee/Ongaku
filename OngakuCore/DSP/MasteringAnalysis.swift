//
//  MasteringAnalysis.swift
//  OngakuCore
//

import Foundation

/// What Ongaku Mastering learns by listening to a song, and the settings it chooses from it.
///
/// While it listens, the plug-in hands over a `Block` every 100 ms: the loudness, the energy
/// in ten octave bands, the mid and side energy and the true peak. `analyse` gates them as
/// loudness is gated (EBU R128: silence and the quietest passages don't count), then turns
/// the song's measurements into settings with a few plain rules, each kept gentle:
///
/// - EQ: the song's octave balance against `reference`, a typical finished master's. Half
///   of each difference over 1 dB is corrected, at most 3 dB.
/// - Dynamics: how far the peaks stand above the loudness. A mix that's already dense is
///   barely compressed; a peaky one gets up to 2:1, from just under its loud passages.
/// - Width: a narrow mix is widened a little; one whose sides cancel isn't widened at all.
/// - Loudness: the gated integrated loudness, from which the limiter's make-up is worked out.
///
/// The rules are deliberately simple so they're easy to tune by ear; the numbers are below.
public enum MasteringAnalysis {
  /// One 100 ms step of the song.
  public struct Block: Sendable, Equatable {
    /// Momentary loudness (the last 400 ms, LUFS).
    public var loudness: Double
    /// Energy (mean square) in each of `bandCenters`, of the mid signal; 0 for bands past
    /// the sample rate's reach.
    public var bands: [Double]
    /// Mean square of the mid ((L + R) / 2) and the side ((L − R) / 2).
    public var mid: Double
    public var side: Double
    /// The highest true peak in the step (linear).
    public var truePeak: Double

    public init(loudness: Double, bands: [Double], mid: Double, side: Double, truePeak: Double) {
      self.loudness = loudness
      self.bands = bands
      self.mid = mid
      self.side = side
      self.truePeak = truePeak
    }
  }

  /// The octave bands' centres (Hz).
  public static let bandCenters: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

  /// A typical finished master's balance, as these bands measure it (dB, relative to pink
  /// noise, which reads the same in every band): a full low end, then falling gently above
  /// 1 kHz. Tuned by ear; only the shape matters, not the level.
  public static let reference: [Double] = [2, 6, 6, 3, 1, 0, -2, -4.5, -7.5, -13]

  /// The settings for the song, and what was found, to show.
  public struct Result: Codable, Sendable, Equatable {
    /// Gated integrated loudness (LUFS).
    public var loudness: Double
    /// The highest true peak (dBTP).
    public var truePeak: Double
    /// How far the peaks stand above the loudness (dB): about 8–11 for a finished master,
    /// 14 or more for an unmastered mix.
    public var peakToLoudness: Double
    /// How the song's balance differs from `reference`, per band (dB; nil where unmeasured).
    public var balance: [Double?]
    /// Side energy against mid (dB): about −10 for a typical stereo mix; above 0, the sides
    /// largely cancel in mono.
    public var sideToMid: Double
    /// The EQ: Low Shelf, Low-Mid, Presence, Air, High Shelf (dB).
    public var eq: [Double]
    public var threshold: Double
    public var ratio: Double
    /// Width (0–100 %).
    public var width: Double
    /// Seconds that counted (louder than the gates).
    public var seconds: Double

    public init(
      loudness: Double, truePeak: Double, peakToLoudness: Double, balance: [Double?], sideToMid: Double, eq: [Double],
      threshold: Double, ratio: Double, width: Double, seconds: Double
    ) {
      self.loudness = loudness
      self.truePeak = truePeak
      self.peakToLoudness = peakToLoudness
      self.balance = balance
      self.sideToMid = sideToMid
      self.eq = eq
      self.threshold = threshold
      self.ratio = ratio
      self.width = width
      self.seconds = seconds
    }
  }

  /// Less than this much of the song (gated) is too little to go on.
  public static let minimumSeconds = 10.0

  /// The song's settings, or nil if fewer than `minimumSeconds` of it were loud enough.
  public static func analyse(_ blocks: [Block]) -> Result? {
    // EBU R128's gates: −70 LUFS, then 10 LU under the loudness of what's left.
    let audible = blocks.filter { $0.loudness > -70 }
    guard !audible.isEmpty else { return nil }
    let relativeGate = meanLoudness(audible) - 10
    let gated = audible.filter { $0.loudness > relativeGate }
    let seconds = Double(gated.count) / 10
    guard seconds >= minimumSeconds else { return nil }
    let loudness = meanLoudness(gated)

    let peak = blocks.map(\.truePeak).max() ?? 0
    let truePeak = peak > 0 ? 20 * log10(peak) : -120
    let peakToLoudness = truePeak - loudness

    let balance = balance(of: gated)

    func deviation(_ weights: [Int: Double]) -> Double {
      var sum = 0.0, total = 0.0
      for (band, weight) in weights {
        guard let value = balance[band] else { continue }
        sum += value * weight
        total += weight
      }
      return total > 0 ? sum / total : 0
    }
    let eq = [
      deviation([0: 0.5, 1: 1, 2: 1]),  // Low Shelf, 100 Hz
      deviation([3: 1]),  // Low-Mid, 250 Hz
      deviation([6: 1, 7: 1]),  // Presence, 3 kHz
      deviation([8: 1]),  // Air, 7 kHz
      deviation([9: 1, 8: 0.5]),  // High Shelf, 10 kHz
    ].map(correction)

    // Dynamics: the louder passages (the top tenth of the steps) set the threshold.
    let ratio: Double = peakToLoudness > 14 ? 2 : peakToLoudness > 10 ? 1.5 : 1
    let loud = gated.map(\.loudness).sorted()
    let upper = loud[min(loud.count - 1, Int(Double(loud.count) * 0.9))]
    let threshold = min(max(upper - 3, -40), 0)

    let mid = gated.map(\.mid).reduce(0, +), side = gated.map(\.side).reduce(0, +)
    let sideToMid = mid > 0 ? 10 * log10(max(side, 1e-12) / mid) : 0
    let width: Double = sideToMid > 0 ? 0 : sideToMid < -20 ? 40 : sideToMid < -14 ? 20 : 0

    return Result(
      loudness: loudness, truePeak: truePeak, peakToLoudness: peakToLoudness, balance: balance, sideToMid: sideToMid,
      eq: eq, threshold: threshold, ratio: ratio, width: width, seconds: seconds)
  }

  /// How steps' balance differs from `reference`, per band (dB; nil where unmeasured), with
  /// the level taken out: the median over 63 Hz–8 kHz, so one or two bands that stand out
  /// (the very thing to correct) don't move it.
  static func balance(of gated: [Block]) -> [Double?] {
    guard !gated.isEmpty else { return [Double?](repeating: nil, count: bandCenters.count) }
    var spectrum = [Double?](repeating: nil, count: bandCenters.count)
    for band in bandCenters.indices {
      let energy = gated.map { $0.bands.indices.contains(band) ? $0.bands[band] : 0 }.reduce(0, +)
      if energy > 0 { spectrum[band] = 10 * log10(energy / Double(gated.count)) - reference[band] }
    }
    let middle = (1...8).compactMap { spectrum[$0] }.sorted()
    let offset = middle.isEmpty ? 0 : (middle[(middle.count - 1) / 2] + middle[middle.count / 2]) / 2
    return spectrum.map { $0.map { $0 - offset } }
  }

  /// Half of a difference beyond 1 dB, the other way, at most 3 dB.
  static func correction(_ deviation: Double) -> Double {
    let excess = abs(deviation) - 1
    guard excess > 0 else { return 0 }
    return min(max(-0.5 * excess * (deviation > 0 ? 1 : -1), -3), 3)
  }

  /// The loudness of a set of steps together (their energies averaged, as R128 does).
  static func meanLoudness(_ blocks: [Block]) -> Double {
    let energy = blocks.map { pow(10, ($0.loudness + 0.691) / 10) }.reduce(0, +) / Double(blocks.count)
    return -0.691 + 10 * log10(energy)
  }
}
