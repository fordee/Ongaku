//
//  PitchDSP.swift
//  OngakuCore
//

import Accelerate
import Foundation

/// A note found in monophonic audio, as Flex Pitch shows it.
public struct DetectedNote: Sendable, Equatable {
  /// Seconds into the audio.
  public var start: Double
  public var end: Double
  /// The note's average pitch, as a MIDI note number with cents (60.25 is C3 a quarter
  /// tone sharp… a quarter of a semitone).
  public var pitch: Double

  public init(start: Double, end: Double, pitch: Double) {
    self.start = start
    self.end = end
    self.pitch = pitch
  }
}

/// Finds the pitch of monophonic audio (a voice or solo instrument) and splits it into
/// notes, with the YIN method: for each short frame, the lag where the signal best matches
/// itself is its period.
public enum PitchDetector {
  /// Pitches sung or played: 60 Hz to 1.2 kHz.
  static let lowestFrequency = 60.0
  static let highestFrequency = 1_200.0
  /// How closely a frame must match itself to count as pitched (YIN's threshold).
  static let threshold: Float = 0.15
  /// Notes shorter than this are dropped (they're consonants and slides).
  public static let shortestNote = 0.06

  /// The pitch every hop (`hopSeconds` apart): a MIDI note number, or `nil` where there's
  /// no clear pitch (silence, breaths, noise).
  public static func pitchTrack(_ samples: [Float], sampleRate: Double, hopSeconds: Double = 0.01) -> [Double?] {
    let maxLag = Int(sampleRate / lowestFrequency)
    let minLag = max(2, Int(sampleRate / highestFrequency))
    let window = maxLag  // Enough to hold two periods of the lowest pitch with the lag.
    let hop = max(1, Int(hopSeconds * sampleRate))
    guard samples.count > window + maxLag else { return [] }
    let frames = (samples.count - window - maxLag) / hop
    let loudest = samples.map(abs).max() ?? 0
    var track: [Double?] = []
    var difference = [Float](repeating: 0, count: maxLag + 1)
    var correlation = [Float](repeating: 0, count: maxLag + 1)

    samples.withUnsafeBufferPointer { pointer in
      let base = pointer.baseAddress!
      for frame in 0..<frames {
        let start = frame * hop
        // Too quiet to have a pitch.
        var peak: Float = 0
        vDSP_maxmgv(base + start, 1, &peak, vDSP_Length(window))
        guard peak > loudest * 0.05 else { track.append(nil); continue }

        // d(τ) = Σ (x[j] - x[j+τ])² = energy(0) + energy(τ) - 2·r(τ), with r from vDSP_conv.
        vDSP_conv(base + start, 1, base + start, 1, &correlation, 1, vDSP_Length(maxLag + 1), vDSP_Length(window))
        var energy0: Float = 0
        vDSP_svesq(base + start, 1, &energy0, vDSP_Length(window))
        var energyLag = energy0
        for lag in 0...maxLag {
          if lag > 0 {
            // Slide the lagged window's energy along by one sample.
            let leaving = base[start + lag - 1]
            let entering = base[start + lag + window - 1]
            energyLag += entering * entering - leaving * leaving
          }
          difference[lag] = energy0 + energyLag - 2 * correlation[lag]
        }
        // Cumulative mean normalised difference, then the first dip below the threshold.
        var runningSum: Float = 0
        var bestLag: Int?
        var normalised = [Float](repeating: 1, count: maxLag + 1)
        for lag in 1...maxLag {
          runningSum += difference[lag]
          normalised[lag] = runningSum > 0 ? difference[lag] * Float(lag) / runningSum : 1
        }
        var lag = minLag
        while lag < maxLag {
          if normalised[lag] < threshold {
            while lag + 1 < maxLag, normalised[lag + 1] < normalised[lag] { lag += 1 }
            bestLag = lag
            break
          }
          lag += 1
        }
        guard let found = bestLag else { track.append(nil); continue }
        // Parabolic interpolation between neighbouring lags for a finer period.
        let a = normalised[found - 1], b = normalised[found], c = normalised[min(found + 1, maxLag)]
        let denominator = a - 2 * b + c
        let offset = denominator != 0 ? Double((a - c) / (2 * denominator)) : 0
        let frequency = sampleRate / (Double(found) + offset)
        track.append(69 + 12 * log2(frequency / 440))
      }
    }
    return track
  }

  /// Notes: runs of pitched frames that stay within half a semitone of where they settle,
  /// at least `shortestNote` long.
  public static func notes(_ samples: [Float], sampleRate: Double) -> [DetectedNote] {
    let hop = 0.01
    let track = pitchTrack(samples, sampleRate: sampleRate, hopSeconds: hop)
    var notes: [DetectedNote] = []
    var current: [Double] = []
    var startFrame = 0

    func finish(at frame: Int) {
      defer { current = [] }
      let duration = Double(frame - startFrame) * hop
      guard duration >= shortestNote else { return }
      let sorted = current.sorted()
      notes.append(DetectedNote(start: Double(startFrame) * hop, end: Double(frame) * hop, pitch: sorted[sorted.count / 2]))
    }

    for (frame, pitch) in track.enumerated() {
      guard let pitch else {
        if !current.isEmpty { finish(at: frame) }
        continue
      }
      if current.isEmpty {
        startFrame = frame
        current = [pitch]
        continue
      }
      let sorted = current.sorted()
      let median = sorted[sorted.count / 2]
      if abs(pitch - median) > 0.5, current.count >= 3 {
        // A new note starts here.
        finish(at: frame)
        startFrame = frame
        current = [pitch]
      } else {
        current.append(pitch)
      }
    }
    if !current.isEmpty { finish(at: track.count) }
    return notes
  }
}

/// A retuned note, as Flex Pitch stores it: the stretch of the region's audio it covers,
/// and how far it's moved, in semitones.
public struct PitchEdit: Identifiable, Codable, Sendable, Equatable, Hashable {
  public var id: UUID
  /// Seconds into the region's audio (as recorded).
  public var start: Double
  public var end: Double
  public var semitones: Double

  public init(id: UUID = UUID(), start: Double, end: Double, semitones: Double) {
    self.id = id
    self.start = start
    self.end = end
    self.semitones = semitones
  }
}

/// Shifts the pitch of parts of audio without changing their timing: each part is
/// time-stretched by the pitch ratio (WSOLA) and then played back faster or slower by the
/// same ratio, and blended into the untouched audio around it.
public enum PitchShifter {
  /// How long the blend into each retuned part takes, at each end.
  static let blend = 0.01

  public static func apply(_ edits: [PitchEdit], to channels: [[Float]], sampleRate: Double) -> [[Float]] {
    var output = channels
    let count = channels.map(\.count).min() ?? 0
    let blendFrames = max(1, Int(blend * sampleRate))
    for edit in edits where abs(edit.semitones) > 0.001 {
      // A little either side, so the blend has shifted audio to use.
      let start = max(0, Int(edit.start * sampleRate) - blendFrames)
      let end = min(count, Int(edit.end * sampleRate) + blendFrames)
      guard end - start > blendFrames * 4 else { continue }
      let ratio = pow(2, edit.semitones / 12)
      let part = channels.map { Array($0[start..<end]) }
      guard let shifted = shift(part, ratio: ratio, sampleRate: sampleRate) else { continue }
      for channel in output.indices {
        for index in 0..<(end - start) {
          // Fade from the original into the shifted audio and back.
          let fromStart = Float(index) / Float(blendFrames)
          let fromEnd = Float(end - start - 1 - index) / Float(blendFrames)
          let mix = min(1, fromStart, fromEnd)
          output[channel][start + index] = output[channel][start + index] * (1 - mix) + shifted[channel][index] * mix
        }
      }
    }
    return output
  }

  /// The same audio `ratio` times higher (2 is an octave up), the same length.
  static func shift(_ channels: [[Float]], ratio: Double, sampleRate: Double) -> [[Float]]? {
    let count = channels.map(\.count).min() ?? 0
    let stretchedCount = Int((Double(count) * ratio).rounded())
    guard let stretched = FlexRenderer.wsola(channels, sampleRate: sampleRate, frameCount: stretchedCount, sourceTime: { $0 / ratio })
    else { return nil }
    // Play the stretched audio back `ratio` times faster: linear interpolation.
    return stretched.map { samples in
      var output = [Float](repeating: 0, count: count)
      for index in 0..<count {
        let position = Double(index) * ratio
        let lower = Int(position)
        guard lower + 1 < samples.count else { break }
        let fraction = Float(position - Double(lower))
        output[index] = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
      }
      return output
    }
  }
}
