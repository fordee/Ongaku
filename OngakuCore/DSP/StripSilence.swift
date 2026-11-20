//
//  StripSilence.swift
//  OngakuCore
//

import Accelerate
import Foundation

/// Logic's Strip Silence: finds the stretches of a recording with sound in them, so the
/// silence between can be removed (see `StripSilence`).
public enum SilenceDetector {
  /// Strip Silence's settings, as Logic's dialog has them.
  public struct Settings: Sendable, Equatable {
    /// Below this level (dBFS) is silence.
    public var threshold: Double
    /// Gaps shorter than this (seconds) are kept, so a phrase isn't cut into syllables.
    public var minimumSilence: Double
    /// Kept before each sound starts, for its attack (seconds).
    public var preAttack: Double
    /// Kept after each sound ends, for its tail (seconds).
    public var postRelease: Double

    public init(threshold: Double = -40, minimumSilence: Double = 0.2, preAttack: Double = 0.02, postRelease: Double = 0.1) {
      self.threshold = threshold
      self.minimumSilence = minimumSilence
      self.preAttack = preAttack
      self.postRelease = postRelease
    }
  }

  /// How finely the level is measured.
  static let blockSeconds = 0.01

  /// The stretches with sound, in seconds from the start of `samples` (one channel, or
  /// several mixed), padded and joined as `settings` say.
  public static func sounds(in samples: [Float], sampleRate: Double, settings: Settings) -> [Range<Double>] {
    let block = max(1, Int(sampleRate * blockSeconds))
    guard samples.count >= block, sampleRate > 0 else { return [] }
    let threshold = Float(pow(10, settings.threshold / 20))
    let duration = Double(samples.count) / sampleRate

    // Which blocks have a peak above the threshold.
    var loud: [Range<Double>] = []
    var start = 0
    while start < samples.count {
      let end = min(start + block, samples.count)
      let peak = samples[start..<end].withUnsafeBufferPointer { vDSP.maximumMagnitude($0) }
      if peak >= threshold {
        let range = Double(start) / sampleRate..<Double(end) / sampleRate
        if let last = loud.last, last.upperBound >= range.lowerBound {
          loud[loud.count - 1] = last.lowerBound..<range.upperBound
        } else {
          loud.append(range)
        }
      }
      start = end
    }

    // Short gaps stay; each sound gets its attack and tail.
    var sounds: [Range<Double>] = []
    for range in loud {
      let padded = max(0, range.lowerBound - settings.preAttack)..<min(duration, range.upperBound + settings.postRelease)
      if let last = sounds.last, padded.lowerBound - last.upperBound < settings.minimumSilence {
        sounds[sounds.count - 1] = last.lowerBound..<max(last.upperBound, padded.upperBound)
      } else {
        sounds.append(padded)
      }
    }
    return sounds
  }
}

/// Strip Silence on an audio region: it's cut into a region for each stretch of sound
/// (in seconds from the region's start, as `SilenceDetector` finds them) and the silence
/// between is removed. One undo step.
public struct StripSilence: EditCommand {
  public var regionID: Region.ID
  public var sounds: [Range<Double>]

  public init(_ regionID: Region.ID, keeping sounds: [Range<Double>]) {
    self.regionID = regionID
    self.sounds = sounds.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
  }

  public var actionName: String { "Strip Silence" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    let region = project.tracks[location.track].regions[location.region]
    guard case .audio = region.content else { throw EditError.invalidValue("Strip Silence works on audio regions.") }
    try region.requireEditable(for: .split)
    guard !sounds.isEmpty else {
      throw EditError.invalidValue("“\(region.name)” is silent at this threshold: lower it to keep something.")
    }

    // The region's time in ticks for each boundary, inside the region.
    let tempoMap = project.tempoMap
    let regionStart = tempoMap.seconds(at: region.start)
    func tick(_ seconds: Double) -> Tick {
      min(max(tempoMap.tickPosition(atSeconds: regionStart + seconds), region.start), region.end)
    }
    let kept = sounds.map { tick($0.lowerBound)..<tick($0.upperBound) }.filter { !$0.isEmpty }
    let cuts = Set(kept.flatMap { [$0.lowerBound, $0.upperBound] }).filter { $0 > region.start && $0 < region.end }.sorted()

    // Cut at every boundary (from the end, so each cut splits what's left of the original
    // region), then remove the pieces that aren't sound.
    var pieceIDs: Set<Region.ID> = [regionID]
    for cut in cuts.reversed() {
      let split = SplitRegion(regionID, at: cut)
      try split.apply(to: &project)
      pieceIDs.insert(split.newRegionID)
    }
    project.tracks[location.track].regions.removeAll { piece in
      pieceIDs.contains(piece.id) && !kept.contains { $0.lowerBound <= piece.start && piece.end <= $0.upperBound }
    }
  }
}
