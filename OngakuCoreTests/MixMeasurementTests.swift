//
//  MixMeasurementTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// The mix analysis measures as the Mastering plug-in's meter does: true peaks, and
/// loudness only from whole 400 ms windows.
struct MixMeasurementTests {
  private let rate = 48_000.0

  @Test func peaksBetweenSamplesAreFound() {
    // A full-scale 12 kHz sine sampled 45° off its peaks: every sample is at 0.707 (-3 dBFS).
    let sine = (0..<48_000).map { Float(cos(Double.pi / 2 * Double($0) + .pi / 4)) }
    let peak = 20 * log10(Double(MixMeasurement.truePeak(sine, in: 4_800..<9_600)))
    #expect(peak > -1 && peak < 0.5, "The true peak is about 0 dBTP (\(peak))")
    let blocks = MixMeasurement.blocks(left: sine, right: sine, sampleRate: rate)
    #expect(MixMeasurement.summary(of: blocks).peak > -1)
  }

  @Test func quietPassagesUseTheirSamplePeak() {
    let quiet = (0..<4_800).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
    #expect(MixMeasurement.truePeak(quiet, in: 0..<quiet.count) == quiet.map(abs).max())
  }

  @Test func loudnessWaitsForAWholeWindow() {
    // A steady 1 kHz tone: the first three 100 ms blocks don't have 400 ms behind them yet.
    let tone = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
    let blocks = MixMeasurement.blocks(left: tone, right: tone, sampleRate: rate)
    #expect(blocks.prefix(3).allSatisfy { $0.loudness == -120 })
    #expect(blocks.dropFirst(3).allSatisfy { $0.loudness > -10 && $0.loudness < 0 })
  }
}
