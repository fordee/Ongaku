//
//  FlexDSP.swift
//  OngakuCore
//

import Accelerate
import Foundation

/// Renders flexed audio: the source (each channel's samples, from the region's start)
/// played through a `FlexMap`, `duration` seconds long. In Flex Pitch mode, `pitchEdits`
/// retune notes first. A `transpose` shifts the pitch of the whole result, keeping its timing.
public enum FlexRenderer {
  public static func render(
    _ channels: [[Float]], map: FlexMap, mode: FlexMode, pitchEdits: [PitchEdit] = [], transpose: Int = 0, sampleRate: Double
  ) -> [[Float]] {
    let rendered = renderFlex(channels, map: map, mode: mode, pitchEdits: pitchEdits, sampleRate: sampleRate)
    guard transpose != 0 else { return rendered }
    return PitchShifter.shift(rendered, ratio: pow(2, Double(transpose) / 12), sampleRate: sampleRate) ?? rendered
  }

  private static func renderFlex(
    _ channels: [[Float]], map: FlexMap, mode: FlexMode, pitchEdits: [PitchEdit], sampleRate: Double
  ) -> [[Float]] {
    let frameCount = Int((map.duration * sampleRate).rounded())
    guard frameCount > 0, !channels.isEmpty else { return channels.map { _ in [] } }
    switch mode {
    case .slicing: return slice(channels, map: map, sampleRate: sampleRate, frameCount: frameCount)
    case .rhythmic: return stretch(channels, map: map, sampleRate: sampleRate, frameCount: frameCount)
    case .pitch:
      let retuned = PitchShifter.apply(pitchEdits, to: channels, sampleRate: sampleRate)
      guard map.anchors.count > 2 else { return retuned.map { Array($0.prefix(frameCount)) + [Float](repeating: 0, count: max(0, frameCount - $0.count)) } }
      return stretch(retuned, map: map, sampleRate: sampleRate, frameCount: frameCount)
    }
  }

  // MARK: - Slicing

  /// Fades at slice edges so a cut doesn't click: 1 ms in, 3 ms out.
  private static let sliceFadeIn = 0.001
  private static let sliceFadeOut = 0.003

  /// Each segment's audio, unstretched, moved to where it plays. A slice moved later leaves
  /// silence after the previous one; one moved earlier cuts the previous one short.
  private static func slice(_ channels: [[Float]], map: FlexMap, sampleRate: Double, frameCount: Int) -> [[Float]] {
    var output = channels.map { _ in [Float](repeating: 0, count: frameCount) }
    let fadeIn = max(1, Int(sliceFadeIn * sampleRate))
    let fadeOut = max(1, Int(sliceFadeOut * sampleRate))
    for (index, segment) in map.segments.enumerated() {
      let sourceStart = Int((segment.source.lowerBound * sampleRate).rounded())
      let targetStart = Int((segment.target.lowerBound * sampleRate).rounded())
      let targetEnd = min(frameCount, Int((segment.target.upperBound * sampleRate).rounded()))
      // A slice plays its own length, or until the next slice starts.
      let sliceLength = Int(((segment.source.upperBound - segment.source.lowerBound) * sampleRate).rounded())
      let length = min(sliceLength, targetEnd - targetStart)
      guard length > 0 else { continue }
      let isLast = index == map.segments.count - 1
      for channel in channels.indices {
        let source = channels[channel]
        for offset in 0..<length {
          let sourceIndex = sourceStart + offset
          guard sourceIndex < source.count else { break }
          var gain: Float = 1
          if index > 0, offset < fadeIn { gain = Float(offset) / Float(fadeIn) }
          if !isLast, offset >= length - fadeOut { gain *= Float(length - offset) / Float(fadeOut) }
          output[channel][targetStart + offset] = source[sourceIndex] * gain
        }
      }
    }
    return output
  }

  // MARK: - Time-stretching (WSOLA)

  /// Window length and hop for WSOLA, at 48 kHz (scaled for other rates): 1024-sample
  /// Hann windows overlapping by half.
  private static let windowSeconds = 1024.0 / 48_000
  /// How far a window may slide from where the time map puts it, to line up with what's
  /// already been written.
  private static let toleranceSeconds = 256.0 / 48_000

  /// Waveform-similarity overlap-add: the output is built from overlapping windows of the
  /// source, each taken from where the time map says (nudged a little to match the audio
  /// already written, so waveforms join without phasing). Pitch is kept; transients are
  /// smeared slightly at extreme stretches, as with any time-domain stretch.
  private static func stretch(_ channels: [[Float]], map: FlexMap, sampleRate: Double, frameCount: Int) -> [[Float]] {
    wsola(channels, sampleRate: sampleRate, frameCount: frameCount) { map.sourceTime(atTarget: min($0, map.duration)) }
      ?? slice(channels, map: map, sampleRate: sampleRate, frameCount: frameCount)
  }

  /// WSOLA producing `frameCount` frames, where the output at `t` seconds comes from the
  /// source at `sourceTime(t)`. `nil` if the source is too short to stretch.
  static func wsola(
    _ channels: [[Float]], sampleRate: Double, frameCount: Int, sourceTime: (Double) -> Double
  ) -> [[Float]]? {
    let window = max(64, Int((windowSeconds * sampleRate).rounded()) & ~1)
    let hop = window / 2
    let tolerance = max(8, Int((toleranceSeconds * sampleRate).rounded()))
    let sourceCount = channels.map(\.count).min() ?? 0
    guard sourceCount > window + 2 * tolerance, frameCount > 0 else { return nil }

    // A periodic Hann window: windows a hop apart add up to one.
    let hann = (0..<window).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(window)) }
    // Matching is done on the channels mixed together.
    var mono = [Float](repeating: 0, count: sourceCount)
    for channel in channels {
      vDSP_vadd(mono, 1, channel, 1, &mono, 1, vDSP_Length(sourceCount))
    }

    var output = channels.map { _ in [Float](repeating: 0, count: frameCount + window) }
    var previousStart = -1
    var outputStart = 0
    while outputStart < frameCount {
      // Where the map says this window's middle comes from.
      let middle = Double(outputStart + hop) / sampleRate
      let nominal = Int((sourceTime(middle) * sampleRate).rounded()) - hop
      var start = min(max(nominal, 0), sourceCount - window)
      if previousStart >= 0 {
        // The audio that would naturally follow the previous window; pick the candidate
        // near `start` most like it.
        let natural = min(previousStart + hop, sourceCount - window)
        let low = max(0, start - tolerance)
        let high = min(sourceCount - window, start + tolerance)
        if high > low {
          start = low + bestMatch(mono, template: natural, candidates: low...high, length: hop)
        }
      }
      for channel in channels.indices {
        channels[channel].withUnsafeBufferPointer { source in
          output[channel].withUnsafeMutableBufferPointer { destination in
            var scaled = [Float](repeating: 0, count: window)
            vDSP_vmul(source.baseAddress! + start, 1, hann, 1, &scaled, 1, vDSP_Length(window))
            vDSP_vadd(destination.baseAddress! + outputStart, 1, scaled, 1, destination.baseAddress! + outputStart, 1, vDSP_Length(window))
          }
        }
      }
      previousStart = start
      outputStart += hop
    }
    // The first half window only had one window's fade-in: bring it up to full level.
    for channel in output.indices {
      for index in 0..<min(hop, frameCount) where hann[index] > 0.05 {
        output[channel][index] /= hann[index]
      }
    }
    return output.map { Array($0.prefix(frameCount)) }
  }

  /// The offset into `candidates` whose `length` samples correlate best with those at
  /// `template`.
  private static func bestMatch(_ signal: [Float], template: Int, candidates: ClosedRange<Int>, length: Int) -> Int {
    let count = candidates.count
    var correlation = [Float](repeating: 0, count: count)
    signal.withUnsafeBufferPointer { samples in
      // vDSP_conv with a positive stride correlates the signal against the template.
      vDSP_conv(
        samples.baseAddress! + candidates.lowerBound, 1, samples.baseAddress! + template, 1, &correlation, 1,
        vDSP_Length(count), vDSP_Length(length))
    }
    var best: Float = 0
    var index: vDSP_Length = 0
    vDSP_maxvi(correlation, 1, &best, &index, vDSP_Length(count))
    return Int(index)
  }
}

/// Finds where notes and hits start in audio: frames whose energy jumps well above the
/// recent level (an energy-flux onset detector), at least `minimumGap` apart.
public enum TransientDetector {
  public static let minimumGap = 0.05

  /// Onsets, in seconds from the start of `samples`.
  public static func detect(_ samples: [Float], sampleRate: Double) -> [Double] {
    let hop = max(32, Int((256.0 / 48_000 * sampleRate).rounded()))
    let frames = samples.count / hop
    guard frames > 4 else { return [] }

    // Energy per hop, in decibels.
    var energy = [Float](repeating: 0, count: frames)
    samples.withUnsafeBufferPointer { pointer in
      for frame in 0..<frames {
        var squares: Float = 0
        vDSP_svesq(pointer.baseAddress! + frame * hop, 1, &squares, vDSP_Length(hop))
        energy[frame] = 10 * log10(max(squares / Float(hop), 1e-10))
      }
    }
    let loudest = energy.max() ?? -100
    // An onset: energy rising by at least 6 dB over the quietest of the previous few hops,
    // and no quieter than 40 dB below the loudest part.
    var onsets: [Double] = []
    var lastOnset = -Double.infinity
    for frame in 4..<frames {
      let before = energy[(frame - 4)..<frame].min() ?? energy[frame]
      let rise = energy[frame] - before
      guard rise >= 6, energy[frame] > loudest - 40 else { continue }
      // Only the start of a rise: the frame before shouldn't already have qualified.
      let previousRise = energy[frame - 1] - (energy[max(0, frame - 5)..<(frame - 1)].min() ?? energy[frame - 1])
      guard previousRise < 6 || energy[frame - 1] <= loudest - 40 else { continue }
      let time = Double(frame * hop) / sampleRate
      if time - lastOnset >= minimumGap {
        onsets.append(time)
        lastOnset = time
      }
    }
    return onsets
  }
}

/// A recording's tempo, as Smart Tempo finds it.
public struct DetectedTempo: Sendable, Equatable {
  public var bpm: Double
  /// Where the first beat falls, in seconds from the start of the audio.
  public var firstBeat: Double
  /// How clearly the audio has a steady pulse, from 0 to 1.
  public var confidence: Double

  public init(bpm: Double, firstBeat: Double, confidence: Double) {
    self.bpm = bpm
    self.firstBeat = firstBeat
    self.confidence = confidence
  }

  /// Seconds per beat.
  public var period: Double { 60 / bpm }
}

/// Finds the tempo of audio with a steady pulse: an onset-strength curve (how sharply the
/// level rises, every 5 ms) is compared with itself shifted by every beat length from 60 to
/// 200 BPM, favouring tempos near 120 the way listeners do; the best is refined with a
/// comb of beats, which also gives the phase (where the beats fall).
public enum TempoDetector {
  static let hop = 0.005
  public static let tempoRange: ClosedRange<Double> = 60...200

  public static func detect(_ samples: [Float], sampleRate: Double) -> DetectedTempo? {
    let envelope = onsetStrength(samples, sampleRate: sampleRate)
    let minLag = Int((60 / tempoRange.upperBound / hop).rounded(.down))
    let maxLag = Int((60 / tempoRange.lowerBound / hop).rounded(.up))
    guard envelope.count > maxLag * 3 else { return nil }

    // Autocorrelation of the onset curve at each beat length.
    var autocorrelation = [Float](repeating: 0, count: maxLag + 1)
    let length = envelope.count - maxLag
    vDSP_conv(envelope, 1, envelope, 1, &autocorrelation, 1, vDSP_Length(maxLag + 1), vDSP_Length(length))
    guard autocorrelation[0] > 0 else { return nil }
    var bestLag = minLag
    var bestScore = -Double.infinity
    for lag in minLag...maxLag {
      let bpm = 60 / (Double(lag) * hop)
      // A gentle preference for tempos near 120 BPM (log-Gaussian, about an octave wide).
      let weight = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
      let score = Double(autocorrelation[lag]) * weight
      if score > bestScore {
        bestScore = score
        bestLag = lag
      }
    }

    // Refine the beat length to a fraction of a hop, and find the phase, with a comb.
    var best = (period: Double(bestLag), phase: 0.0, score: -Double.infinity)
    var period = Double(bestLag) - 1
    while period <= Double(bestLag) + 1 {
      var phase = 0.0
      while phase < period {
        var score = 0.0
        var position = phase
        while position < Double(envelope.count) {
          score += Double(envelope[Int(position)])
          position += period
        }
        // Average per beat, so short periods (more beats) aren't favoured.
        score /= Double(envelope.count) / period
        if score > best.score { best = (period, phase, score) }
        phase += 1
      }
      period += 0.02
    }
    let confidence = min(1, max(0, Double(autocorrelation[bestLag] / autocorrelation[0])))
    return DetectedTempo(bpm: 60 / (best.period * hop), firstBeat: best.phase * hop, confidence: confidence)
  }

  /// How sharply the level rises, every `hop` seconds (half-wave rectified level flux).
  static func onsetStrength(_ samples: [Float], sampleRate: Double) -> [Float] {
    let hopFrames = max(1, Int(hop * sampleRate))
    let frames = samples.count / hopFrames
    guard frames > 1 else { return [] }
    var energy = [Float](repeating: 0, count: frames)
    samples.withUnsafeBufferPointer { pointer in
      for frame in 0..<frames {
        var squares: Float = 0
        vDSP_svesq(pointer.baseAddress! + frame * hopFrames, 1, &squares, vDSP_Length(hopFrames))
        // The level itself (RMS), not its logarithm: accented beats must stand out from
        // quieter off-beats, or a song is easily heard at twice its tempo.
        energy[frame] = (squares / Float(hopFrames)).squareRoot()
      }
    }
    var flux = [Float](repeating: 0, count: frames)
    for frame in 1..<frames {
      flux[frame] = max(0, energy[frame] - energy[frame - 1])
    }
    return flux
  }
}
