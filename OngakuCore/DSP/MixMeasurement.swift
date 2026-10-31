//
//  MixMeasurement.swift
//  OngakuCore
//

import Accelerate
import Foundation

/// Measures a rendered mix the way Ongaku Mastering's Listen does: a
/// `MasteringAnalysis.Block` every 100 ms (momentary loudness, octave-band energy of the mid
/// signal, mid and side energy, peak), so a mix can be described against the same reference
/// as Mastering uses, for the whole song or any part of it.
///
/// Loudness is K-weighted as ITU-R BS.1770 and EBU R128 describe. Peaks are sample peaks,
/// which can read a little under true peaks.
public enum MixMeasurement {
  /// What a stretch of the mix measures.
  public struct Summary: Sendable, Equatable {
    /// Gated loudness (LUFS), or nil if it's silent.
    public var loudness: Double?
    /// The loudest momentary loudness (LUFS).
    public var maximumLoudness: Double?
    /// The highest sample peak (dBFS).
    public var peak: Double
    /// How far the peaks stand above the loudness (dB).
    public var peakToLoudness: Double?
    /// Against Mastering's reference balance, per octave band (dB; nil where unmeasured).
    public var balance: [Double?]
    /// Side energy against mid (dB): about −10 for a typical stereo mix.
    public var sideToMid: Double?
  }

  public static let blockSeconds = 0.1

  /// A block for every 100 ms of a stereo mix.
  public static func blocks(left: [Float], right: [Float], sampleRate: Double) -> [MasteringAnalysis.Block] {
    let count = min(left.count, right.count)
    let step = max(1, Int(sampleRate * blockSeconds))
    guard count >= step, sampleRate > 0 else { return [] }
    var weightingLeft = kWeighting(sampleRate: sampleRate)
    var weightingRight = kWeighting(sampleRate: sampleRate)
    let nyquist = sampleRate / 2
    var bandFilters = MasteringAnalysis.bandCenters.map { center in
      center * 1.41 < nyquist ? bandPass(center: center, sampleRate: sampleRate) : nil
    }

    var weightedEnergy: [Double] = []
    var blocks: [MasteringAnalysis.Block] = []
    var start = 0
    while start + step <= count {
      let range = start..<(start + step)
      let leftStep = Array(left[range]), rightStep = Array(right[range])
      let weighted = meanSquare(weightingLeft.apply(input: leftStep)) + meanSquare(weightingRight.apply(input: rightStep))
      weightedEnergy.append(weighted)
      // Momentary loudness: the last 400 ms.
      let window = weightedEnergy.suffix(4)
      let energy = window.reduce(0, +) / Double(window.count)
      let loudness = energy > 0 ? -0.691 + 10 * log10(energy) : -120

      let mid = vDSP.multiply(0.5, vDSP.add(leftStep, rightStep))
      let side = vDSP.multiply(0.5, vDSP.subtract(leftStep, rightStep))
      var bands: [Double] = []
      for index in bandFilters.indices {
        if bandFilters[index] != nil {
          bands.append(meanSquare(bandFilters[index]!.apply(input: mid)))
        } else {
          bands.append(0)
        }
      }
      let peak = max(vDSP.maximumMagnitude(leftStep), vDSP.maximumMagnitude(rightStep))
      blocks.append(MasteringAnalysis.Block(
        loudness: loudness, bands: bands, mid: meanSquare(mid), side: meanSquare(side), truePeak: Double(peak)))
      start += step
    }
    return blocks
  }

  /// What some blocks measure together, gated as R128 gates loudness (silence and the
  /// quietest passages don't count).
  public static func summary(of blocks: [MasteringAnalysis.Block]) -> Summary {
    let peakLinear = blocks.map(\.truePeak).max() ?? 0
    let peak = peakLinear > 0 ? 20 * log10(peakLinear) : -120
    let audible = blocks.filter { $0.loudness > -70 }
    guard !audible.isEmpty else {
      return Summary(loudness: nil, maximumLoudness: nil, peak: peak, peakToLoudness: nil, balance: MasteringAnalysis.balance(of: []), sideToMid: nil)
    }
    let relativeGate = MasteringAnalysis.meanLoudness(audible) - 10
    let gated = audible.filter { $0.loudness > relativeGate }
    let loudness = MasteringAnalysis.meanLoudness(gated)
    let mid = gated.map(\.mid).reduce(0, +), side = gated.map(\.side).reduce(0, +)
    return Summary(
      loudness: loudness, maximumLoudness: audible.map(\.loudness).max(), peak: peak, peakToLoudness: peak - loudness,
      balance: MasteringAnalysis.balance(of: gated), sideToMid: mid > 0 ? 10 * log10(max(side, 1e-12) / mid) : nil)
  }

  // MARK: - Filters

  private static func meanSquare(_ samples: [Float]) -> Double {
    samples.isEmpty ? 0 : Double(vDSP.sumOfSquares(samples)) / Double(samples.count)
  }

  /// BS.1770's K-weighting: a high shelf for the head's effect, then a high-pass.
  private static func kWeighting(sampleRate: Double) -> vDSP.Biquad<Float> {
    // Stage 1: +4 dB high shelf at 1682 Hz.
    let gain = 3.999843853973347, shelfFrequency = 1681.974450955533, shelfQ = 0.7071752369554196
    let a = pow(10, gain / 40)
    var w0 = 2 * Double.pi * shelfFrequency / sampleRate
    var alpha = sin(w0) / (2 * shelfQ)
    let root = 2 * sqrt(a) * alpha
    let shelf = normalized(
      b: [a * ((a + 1) + (a - 1) * cos(w0) + root), -2 * a * ((a - 1) + (a + 1) * cos(w0)), a * ((a + 1) + (a - 1) * cos(w0) - root)],
      a: [(a + 1) - (a - 1) * cos(w0) + root, 2 * ((a - 1) - (a + 1) * cos(w0)), (a + 1) - (a - 1) * cos(w0) - root])
    // Stage 2: high-pass at 38 Hz.
    let passFrequency = 38.13547087602444, passQ = 0.5003270373238773
    w0 = 2 * Double.pi * passFrequency / sampleRate
    alpha = sin(w0) / (2 * passQ)
    let highPass = normalized(
      b: [(1 + cos(w0)) / 2, -(1 + cos(w0)), (1 + cos(w0)) / 2], a: [1 + alpha, -2 * cos(w0), 1 - alpha])
    return vDSP.Biquad(coefficients: shelf + highPass, channelCount: 1, sectionCount: 2, ofType: Float.self)!
  }

  /// An octave-wide band-pass (0 dB at the centre).
  private static func bandPass(center: Double, sampleRate: Double) -> vDSP.Biquad<Float>? {
    let w0 = 2 * Double.pi * center / sampleRate
    let alpha = sin(w0) / (2 * 1.414)
    let coefficients = normalized(b: [alpha, 0, -alpha], a: [1 + alpha, -2 * cos(w0), 1 - alpha])
    return vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Float.self)
  }

  /// vDSP's order: b0, b1, b2, a1, a2, divided by a0.
  private static func normalized(b: [Double], a: [Double]) -> [Double] {
    [b[0] / a[0], b[1] / a[0], b[2] / a[0], a[1] / a[0], a[2] / a[0]]
  }
}
