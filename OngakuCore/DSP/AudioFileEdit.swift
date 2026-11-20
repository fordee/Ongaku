//
//  AudioFileEdit.swift
//  OngakuCore
//

import Accelerate
import Foundation

/// The Audio File Editor's functions, as Logic's Functions menu has them. Each changes the
/// samples of a stretch of a file; the app writes the result as a new file and swaps it in
/// with `ReplaceAudioFile`, so every edit can be undone.
public enum AudioFileEdit: Sendable, Equatable {
  /// Raises or lowers the stretch so its loudest sample reaches `peak` dBFS.
  case normalize(peak: Double)
  /// Changes the level by this many dB.
  case gain(Double)
  /// Fades from silence to full level across the stretch.
  case fadeIn
  /// Fades from full level to silence across the stretch.
  case fadeOut
  case silence
  case reverse
  /// Turns the waveform upside down (polarity).
  case invert
  /// Takes out any constant offset, so the waveform centres on zero.
  case removeDCOffset

  public var actionName: String {
    switch self {
    case .normalize: "Normalize"
    case .gain: "Change Gain"
    case .fadeIn: "Fade In"
    case .fadeOut: "Fade Out"
    case .silence: "Silence"
    case .reverse: "Reverse"
    case .invert: "Invert"
    case .removeDCOffset: "Remove DC Offset"
    }
  }

  /// Applies the edit to `frames` of every channel (all channels share one normalize gain
  /// and one DC offset each, as Logic's do). Frames outside the channels are ignored.
  public func apply(to channels: inout [[Float]], frames: Range<Int>) {
    let length = channels.first?.count ?? 0
    let range = max(0, frames.lowerBound)..<min(length, frames.upperBound)
    guard !range.isEmpty else { return }
    switch self {
    case .normalize(let peak):
      let loudest = channels.map { channel in channel[range].withUnsafeBufferPointer { vDSP.maximumMagnitude($0) } }.max() ?? 0
      guard loudest > 0 else { return }
      scale(&channels, range) { _ in Float(pow(10, peak / 20)) / loudest }
    case .gain(let decibels):
      scale(&channels, range) { _ in Float(pow(10, decibels / 20)) }
    case .fadeIn:
      let count = Float(range.count)
      scale(&channels, range) { Float($0 - range.lowerBound) / count }
    case .fadeOut:
      let count = Float(range.count)
      scale(&channels, range) { Float(range.upperBound - $0) / count }
    case .silence:
      scale(&channels, range) { _ in 0 }
    case .invert:
      scale(&channels, range) { _ in -1 }
    case .reverse:
      for channel in channels.indices { channels[channel][range].reverse() }
    case .removeDCOffset:
      for channel in channels.indices {
        let mean = channels[channel][range].withUnsafeBufferPointer { vDSP.mean($0) }
        for index in range { channels[channel][index] -= mean }
      }
    }
  }

  private func scale(_ channels: inout [[Float]], _ range: Range<Int>, by factor: (Int) -> Float) {
    for channel in channels.indices {
      for index in range { channels[channel][index] *= factor(index) }
    }
  }
}
