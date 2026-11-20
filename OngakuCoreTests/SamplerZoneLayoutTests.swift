//
//  SamplerZoneLayoutTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Laying the Sampler's samples out across the keyboard, as Logic's Sampler does.
struct SamplerZoneLayoutTests {
  @Test func pitchedSamplesShareTheKeysHalfwayBetweenTheirRoots() {
    // Given out of order, as files often are.
    let zones = SamplerZoneLayout.map([.init(root: 64), .init(root: 48), .init(root: 72)])
    #expect(zones[1] == SamplerZoneSettings(lowKey: 0, highKey: 56, root: 48))
    #expect(zones[0] == SamplerZoneSettings(lowKey: 57, highKey: 68, root: 64))
    #expect(zones[2] == SamplerZoneSettings(lowKey: 69, highKey: 127, root: 72))
  }

  @Test func samplesOnTheSameNoteBecomeVelocityLayersQuietestSoftest() {
    let zones = SamplerZoneLayout.map([.init(root: 60, level: 0.9), .init(root: 60, level: 0.2), .init(root: 60, level: 0.5)])
    #expect(zones.map(\.lowVelocity) == [85, 1, 43])
    #expect(zones.map(\.highVelocity) == [127, 42, 84])
    #expect(zones.allSatisfy { $0.lowKey == 0 && $0.highKey == 127 && $0.root == 60 })
  }

  @Test func unpitchedSamplesEachGetAKeyFromC1() {
    let zones = SamplerZoneLayout.map([.init(root: nil), .init(root: nil), .init(root: nil)])
    #expect(zones.map(\.lowKey) == [36, 37, 38])
    #expect(zones.allSatisfy { $0.lowKey == $0.highKey && $0.root == $0.lowKey })
  }

  @Test func addedZonesFitAroundTheOnesThere() {
    let existing = [SamplerZoneSettings(lowKey: 48, highKey: 60, root: 55)]
    let new = SamplerZoneLayout.map([.init(root: 40), .init(root: 72), .init(root: 50)])
    let fitted = SamplerZoneLayout.fit(new, around: existing)
    #expect(fitted[0].lowKey == 0 && fitted[0].highKey == 45, "Up to halfway to 50, and no further")
    #expect(fitted[1].lowKey == 62 && fitted[1].highKey == 127, "From halfway between 50 and 72")
    #expect(fitted[2].lowKey == 50 && fitted[2].highKey == 50, "Its root is taken, so just its root")
  }

  @Test(arguments: [
    ("Piano C3", 60), ("Bass_F#1_mf", 42), ("Strings-Eb2", 51), ("Grand A-1", 21), ("Kick", nil), ("Take 12", nil),
    ("Vibes c4 soft", 72), ("Note Bb2", 58),
  ] as [(String, Int?)])
  func notesAreReadFromFileNamesWithMiddleCAsC3(name: String, note: Int?) {
    #expect(SamplerZoneLayout.root(fromName: name) == note)
  }

  @Test func clampingKeepsRangesValidAndTheRightWayRound() {
    let settings = SamplerZoneSettings(lowKey: 90, highKey: 200, lowVelocity: 0, highVelocity: -4, root: 140, tune: 300, gain: -40, pan: 150)
      .clamped()
    #expect(settings == SamplerZoneSettings(lowKey: 90, highKey: 127, lowVelocity: 1, highVelocity: 1, root: 127, tune: 100, gain: -24, pan: 100))
    #expect(SamplerZoneSettings(lowKey: 70, highKey: 50).clamped().lowKey == 50)
    #expect(SamplerZoneSettings().isWholeKeyboard)
  }
}
