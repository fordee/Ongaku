//
//  SpectrumAnalyser.swift
//  OngakuEffects
//

import Accelerate
import Foundation

/// Turns the effect's output (from its analyser tap) into levels at log-spaced
/// frequencies, falling back slowly like a meter.
@MainActor
final class SpectrumAnalyser {
  /// The frequencies the levels are for, 20 Hz to 20 kHz.
  let frequencies: [Float]
  private(set) var levels: [Float]

  private let audioUnit: OngakuEffectsAudioUnit
  private let size = 4_096
  private let transform: vDSP.DiscreteFourierTransform<Float>?
  private let window: [Float]
  private var lastWritten: UInt32 = 0

  /// The quietest level shown.
  static let floor: Float = -96

  init(audioUnit: OngakuEffectsAudioUnit, points: Int = 192) {
    self.audioUnit = audioUnit
    frequencies = (0..<points).map { 20 * powf(1_000, Float($0) / Float(points - 1)) }
    levels = [Float](repeating: Self.floor, count: points)
    transform = try? vDSP.DiscreteFourierTransform(
      count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
  }

  /// Reads the newest audio and updates the levels.
  func update() {
    let written = OngakuAnalyserWritten(audioUnit.analyserWritten)
    defer { lastWritten = written }
    guard written != lastWritten, let transform else {
      // Nothing new (the host has stopped): let the levels fall away.
      levels = levels.map { max(Self.floor, $0 - 3) }
      return
    }

    // The newest `size` samples from the ring (counts wrap with the ring's power-of-two size).
    let capacity = UInt32(OngakuEffectsAudioUnit.analyserCapacity)
    let samples = (0..<size).map { index in
      audioUnit.analyserSamples[Int((written &- UInt32(size) &+ UInt32(index)) % capacity)]
    }
    let windowed = vDSP.multiply(samples, window)
    let (real, imaginary) = transform.transform(real: windowed, imaginary: [Float](repeating: 0, count: size))

    // Magnitudes scaled so a full-scale sine reads 0 dB.
    let scale = 2 / vDSP.sum(window)
    let bins = size / 2
    var magnitudes = [Float](repeating: 0, count: bins)
    for bin in 0..<bins {
      magnitudes[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() * scale
    }

    let sampleRate = Float(audioUnit.outputBusses[0].format.sampleRate)
    let binWidth = sampleRate / Float(size)
    for (point, frequency) in frequencies.enumerated() {
      // Each point takes the loudest bin between it and the next point.
      let next = point + 1 < frequencies.count ? frequencies[point + 1] : frequency * 1.04
      let low = min(bins - 1, Int(frequency / binWidth))
      let high = min(bins - 1, max(low, Int(next / binWidth)))
      let magnitude = magnitudes[low...high].max() ?? 0
      let level = max(Self.floor, 20 * log10f(max(magnitude, 1e-9)))
      levels[point] = max(level, levels[point] - 2)
    }
  }
}
