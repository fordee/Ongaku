//
//  BounceTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct BounceTests {
  private func projectWithRegions(endingAt ends: [Tick]) -> Project {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.regions = ends.map { end in
      Region(name: "Region", start: end - .quarterNotes(4), length: .quarterNotes(4), content: .midi(MIDISequence(notes: [])))
    }
    return Project(tracks: [track])
  }

  @Test func bounceRunsFromTheStartToTheLastRegionEnd() {
    let project = projectWithRegions(endingAt: [.quarterNotes(8), .quarterNotes(22)])
    #expect(project.bounceRange == .zero..<Tick.quarterNotes(22))
  }

  @Test func bounceUsesTheCycleWhenItsOn() {
    var project = projectWithRegions(endingAt: [.quarterNotes(64)])
    project.cycle = CycleRange(isEnabled: true, start: .quarterNotes(8), end: .quarterNotes(24))
    #expect(project.bounceRange == Tick.quarterNotes(8)..<Tick.quarterNotes(24))
  }

  @Test func emptyProjectsHaveNothingToBounce() {
    #expect(Project().bounceRange == nil)
  }

  @Test func playingOncePlaysTheRangeWithoutCycling() throws {
    var project = projectWithRegions(endingAt: [.quarterNotes(64)])
    project.cycle = CycleRange(isEnabled: true, start: .quarterNotes(8), end: .quarterNotes(24))
    let range = try #require(project.bounceRange)
    let plan = PlaybackPlan(project: project.playingOnce(range), startPosition: range.lowerBound)
    // 16 quarter notes at 120 BPM.
    #expect(plan.duration == 8)
  }

  @Test func formatsOnlyOfferBitDepthsTheyCanStore() {
    #expect(BounceSettings(format: .wav, bitDepth: .thirtyTwoFloat).effectiveBitDepth == .thirtyTwoFloat)
    #expect(BounceSettings(format: .aiff, bitDepth: .thirtyTwoFloat).effectiveBitDepth == .twentyFour)
    #expect(BounceSettings(format: .m4a).effectiveBitDepth == nil)
    #expect(BounceSettings(format: .wav, bitDepth: .sixteen).usesDither)
    #expect(!BounceSettings(format: .wav, bitDepth: .twentyFour).usesDither)
  }

  @Test func aacStaysAtOrBelow48kHz() {
    #expect(BounceSettings(format: .m4a, sampleRate: 96_000).effectiveSampleRate == 48_000)
    #expect(BounceSettings(format: .m4a, sampleRate: 44_100).effectiveSampleRate == 44_100)
    #expect(BounceSettings(format: .wav, sampleRate: 96_000).effectiveSampleRate == 96_000)
  }

  @Test func normalizingBringsThePeakToTheTarget() {
    let settings = BounceSettings(normalize: true)
    let gain = settings.normalizationGain(forPeak: 0.5)
    #expect(abs(20 * log10(Double(0.5 * gain)) - settings.normalizationTarget) < 0.0001)
    #expect(settings.normalizationGain(forPeak: 0) == 1)
    #expect(BounceSettings(format: .m4a).normalizationTarget < settings.normalizationTarget)
  }
}
