//
//  MasteringAnalysisTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Ongaku Mastering's rules, fed made-up songs whose measurements are known exactly.
struct MasteringAnalysisTests {
  /// A song of `seconds` at `loudness`, balanced like the reference except for `tilt` (dB
  /// added per band), with peaks `peakToLoudness` over the loudness and the given width.
  private func song(
    seconds: Double = 60, loudness: Double = -20, tilt: [Int: Double] = [:], peakToLoudness: Double = 16,
    sideToMid: Double = -10, quietIntro: Double = 0
  ) -> [MasteringAnalysis.Block] {
    let steps = Int(seconds * 10)
    return (0..<steps).map { step in
      // Loud and quiet passages alternate a little, as music does.
      let level = loudness + (step % 20 < 10 ? 1.5 : -1.5) - (Double(step) < quietIntro * 10 ? 40 : 0)
      let bands = MasteringAnalysis.reference.indices.map { band in
        pow(10, (MasteringAnalysis.reference[band] + (tilt[band] ?? 0) + level) / 10)
      }
      let mid = pow(10, level / 10)
      return MasteringAnalysis.Block(
        loudness: level, bands: bands, mid: mid, side: mid * pow(10, sideToMid / 10),
        truePeak: pow(10, (loudness + peakToLoudness) / 20))
    }
  }

  @Test func aBalancedSongIsLeftAlone() throws {
    let result = try #require(MasteringAnalysis.analyse(song()))
    #expect(abs(result.loudness + 20) < 0.5)
    #expect(result.eq == [0, 0, 0, 0, 0], "No band is more than a dB from the reference")
    #expect(result.width == 0)
    #expect(result.balance.allSatisfy { ($0.map(abs) ?? 0) < 0.01 })
  }

  @Test func heavyLowsAreTurnedDownGently() throws {
    let result = try #require(MasteringAnalysis.analyse(song(tilt: [0: 6, 1: 6, 2: 6])))
    // 6 dB too heavy: half of the 5 dB over the tolerance, capped at 3 dB.
    #expect(abs(result.eq[0] + 2.5) < 0.2, "Low Shelf \(result.eq[0])")
    #expect(result.eq[1...].allSatisfy { abs($0) < 0.3 }, "The rest is left alone: \(result.eq)")
  }

  @Test func aDullSongGetsAir() throws {
    let result = try #require(MasteringAnalysis.analyse(song(tilt: [8: -5, 9: -8])))
    #expect(result.eq[3] > 1, "Air \(result.eq[3])")
    #expect(abs(result.eq[4] - 3) < 0.01, "High Shelf, at the 3 dB cap")
  }

  @Test func harshnessIsTamed() throws {
    let result = try #require(MasteringAnalysis.analyse(song(tilt: [6: 4, 7: 4])))
    #expect(result.eq[2] < -1, "Presence \(result.eq[2])")
  }

  @Test func theLevelOfTheSongDoesntChangeTheEQ() throws {
    let quiet = try #require(MasteringAnalysis.analyse(song(loudness: -26, tilt: [0: 6, 1: 6, 2: 6])))
    let loud = try #require(MasteringAnalysis.analyse(song(loudness: -12, tilt: [0: 6, 1: 6, 2: 6])))
    #expect(zip(quiet.eq, loud.eq).allSatisfy { abs($0 - $1) < 0.01 })
  }

  @Test func peakyMixesAreCompressedAndDenseOnesHardlyAtAll() throws {
    let peaky = try #require(MasteringAnalysis.analyse(song(peakToLoudness: 18)))
    #expect(peaky.ratio == 2)
    // The threshold sits a little under the loud passages (−18.5 LUFS).
    #expect(abs(peaky.threshold - (-21.5)) < 0.1, "Threshold \(peaky.threshold)")
    let dense = try #require(MasteringAnalysis.analyse(song(peakToLoudness: 9)))
    #expect(dense.ratio == 1)
    #expect(abs(dense.peakToLoudness - 9) < 0.5)
  }

  @Test func narrowMixesAreWidenedButCancellingOnesAreNot() throws {
    #expect(try #require(MasteringAnalysis.analyse(song(sideToMid: -24))).width == 40)
    #expect(try #require(MasteringAnalysis.analyse(song(sideToMid: -16))).width == 20)
    #expect(try #require(MasteringAnalysis.analyse(song(sideToMid: -8))).width == 0)
    #expect(try #require(MasteringAnalysis.analyse(song(sideToMid: 2))).width == 0)
  }

  @Test func silenceAndQuietPassagesDontCount() throws {
    // 20 seconds of near-silence first: the gates leave it out of the loudness.
    let result = try #require(MasteringAnalysis.analyse(song(seconds: 80, quietIntro: 20)))
    #expect(abs(result.loudness + 20) < 0.5)
    #expect(abs(result.seconds - 60) < 1)
  }

  @Test func tooLittleMusicGivesNoResult() {
    #expect(MasteringAnalysis.analyse(song(seconds: 8)) == nil)
    #expect(MasteringAnalysis.analyse([]) == nil)
  }

  @Test func bandsPastTheSampleRateArentGuessed() throws {
    // At a low sample rate the top band can't be measured.
    var blocks = song(tilt: [8: -5])
    for index in blocks.indices { blocks[index].bands[9] = 0 }
    let result = try #require(MasteringAnalysis.analyse(blocks))
    #expect(result.balance[9] == nil)
    #expect(result.eq[4] > 0, "The High Shelf follows the 8 kHz band alone")
  }
}
