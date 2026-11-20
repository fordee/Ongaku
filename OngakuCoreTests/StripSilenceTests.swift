//
//  StripSilenceTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Logic's Strip Silence: finding the sounds in a recording, and cutting a region into them.
struct StripSilenceTests {
  private let rate = 48_000.0

  /// Half-second 440 Hz bursts (at -6 dBFS) at the given times, in two seconds of silence.
  private func bursts(at starts: [Double], length: Double = 0.5) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(2 * rate))
    for start in starts {
      for index in Int(start * rate)..<min(samples.count, Int((start + length) * rate)) {
        samples[index] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(index) / rate))
      }
    }
    return samples
  }

  @Test func soundsAreFoundWithTheirAttackAndTail() {
    let settings = SilenceDetector.Settings(threshold: -40, minimumSilence: 0.2, preAttack: 0.02, postRelease: 0.1)
    let sounds = SilenceDetector.sounds(in: bursts(at: [0.2, 1.3]), sampleRate: rate, settings: settings)
    #expect(sounds.count == 2)
    #expect(abs(sounds[0].lowerBound - 0.18) < 0.015 && abs(sounds[0].upperBound - 0.8) < 0.015)
    #expect(abs(sounds[1].lowerBound - 1.28) < 0.015)
  }

  @Test func shortGapsDontCountAsSilence() {
    // Two bursts 0.15 s apart: with half a second's minimum silence they're one sound.
    let samples = bursts(at: [0.2, 0.85])
    let joined = SilenceDetector.sounds(in: samples, sampleRate: rate, settings: .init(minimumSilence: 0.5, postRelease: 0))
    #expect(joined.count == 1)
    let apart = SilenceDetector.sounds(in: samples, sampleRate: rate, settings: .init(minimumSilence: 0.05, postRelease: 0))
    #expect(apart.count == 2)
  }

  @Test func quietSoundsAreSilenceBelowTheThreshold() {
    let quiet = bursts(at: [0.5]).map { $0 * 0.001 }  // About -66 dBFS.
    #expect(SilenceDetector.sounds(in: quiet, sampleRate: rate, settings: .init(threshold: -40)).isEmpty)
    #expect(SilenceDetector.sounds(in: quiet, sampleRate: rate, settings: .init(threshold: -70)).count == 1)
  }

  @Test func theRegionIsCutIntoItsSounds() throws {
    // Four beats at 120 BPM: a two-second region.
    let file = AudioFileReference(fileName: "Vox.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let region = Region(name: "Vox", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(tracks: [Track(name: "Vox", kind: .audio, regions: [region])], audioFiles: [file])

    try StripSilence(region.id, keeping: [0.25..<0.75, 1.25..<1.5]).apply(to: &project)
    let regions = project.tracks[0].regions
    // Half a second is a beat (960 ticks) at 120 BPM.
    #expect(regions.map(\.start) == [Tick(480), Tick(2400)])
    #expect(regions.map(\.length) == [Tick(960), Tick(480)])
    guard case .audio(let second) = regions.last?.content else { Issue.record(); return }
    #expect(second.fileStartFrame == 60_000, "Each piece plays its part of the file")

    #expect(throws: EditError.self) { try StripSilence(region.id, keeping: []).apply(to: &project) }
  }
}
