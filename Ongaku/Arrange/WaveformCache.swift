//
//  WaveformCache.swift
//  Ongaku
//

import AVFAudio
import Foundation
import OngakuCore

/// A peak overview of an audio file: the loudest sample in each block of frames, across all
/// channels. Drawing reads peaks instead of the file. Built off the main actor.
nonisolated struct Waveform: Sendable {
  static let framesPerPeak = 256

  let peaks: [Float]
  let sampleRate: Double

  /// The loudest peak between two frame positions.
  func peak(fromFrame start: Int64, toFrame end: Int64) -> Float {
    let first = max(0, Int(start / Int64(Waveform.framesPerPeak)))
    let last = min(peaks.count - 1, Int(end / Int64(Waveform.framesPerPeak)))
    guard first <= last else { return 0 }
    return peaks[first...last].max() ?? 0
  }
}

/// Computes waveform overviews in the background and keeps them for the window's lifetime.
@MainActor
@Observable
final class WaveformCache {
  private(set) var waveforms: [AudioFileReference.ID: Waveform] = [:]
  @ObservationIgnored private var inFlight: Set<AudioFileReference.ID> = []

  func load(_ file: AudioFileReference, from url: URL?) {
    guard waveforms[file.id] == nil, !inFlight.contains(file.id), let url else { return }
    inFlight.insert(file.id)
    Task {
      let waveform = try? await WaveformCache.computeWaveform(at: url)
      inFlight.remove(file.id)
      waveforms[file.id] = waveform
    }
  }

  @concurrent
  private nonisolated static func computeWaveform(at url: URL) async throws -> Waveform {
    let file = try AVAudioFile(forReading: url)
    let chunkSize = AVAudioFrameCount(Waveform.framesPerPeak * 256)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize) else {
      throw CocoaError(.fileReadUnknown)
    }

    var peaks: [Float] = []
    peaks.reserveCapacity(Int(file.length) / Waveform.framesPerPeak + 1)
    let channelCount = Int(file.processingFormat.channelCount)

    while file.framePosition < file.length {
      try file.read(into: buffer, frameCount: chunkSize)
      let frameCount = Int(buffer.frameLength)
      guard frameCount > 0, let channels = buffer.floatChannelData else { break }

      for blockStart in stride(from: 0, to: frameCount, by: Waveform.framesPerPeak) {
        let blockEnd = min(blockStart + Waveform.framesPerPeak, frameCount)
        var peak: Float = 0
        for channel in 0..<channelCount {
          let samples = channels[channel]
          for frame in blockStart..<blockEnd {
            peak = max(peak, abs(samples[frame]))
          }
        }
        peaks.append(peak)
      }
    }
    return Waveform(peaks: peaks, sampleRate: file.processingFormat.sampleRate)
  }
}
