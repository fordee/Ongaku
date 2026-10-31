//
//  SamplerSampleBuffer.swift
//  OngakuEffects
//

import AVFoundation
import Observation

/// The Sampler's sample: its audio at fixed addresses for the render thread, and how it's
/// saved in the Audio Unit's state (so a song carries its samples with it, in any host).
final class SamplerSampleBuffer: @unchecked Sendable {
  let name: String
  let sampleRate: Double
  let frameCount: Int
  /// One or two channels.
  let channels: [UnsafeMutablePointer<Float>]
  /// What the kernel reads.
  let kernelSample: UnsafeMutablePointer<SamplerSample>
  /// When a file was cut to fit, what was left out ("Only the first 60 s is used."), for
  /// the window to say.
  let notice: String?

  /// Samples are kept to a minute, so songs stay a sensible size.
  static let maximumSeconds = 60.0

  init(name: String, sampleRate: Double, channels source: [[Float]], notice: String? = nil) {
    self.name = name
    self.sampleRate = sampleRate
    self.notice = notice
    let frameCount = source.map(\.count).min() ?? 0
    self.frameCount = frameCount
    channels = source.prefix(2).map { samples in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frameCount))
      samples.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: frameCount) }
      return pointer
    }
    kernelSample = .allocate(capacity: 1)
    kernelSample.initialize(to: SamplerSample(
      left: channels[0], right: channels.count > 1 ? channels[1] : nil, frames: Int64(frameCount), sampleRate: sampleRate))
  }

  deinit {
    for channel in channels { channel.deallocate() }
    kernelSample.deallocate()
  }

  var duration: Double { Double(frameCount) / sampleRate }

  // MARK: - Files

  enum LoadError: LocalizedError {
    case empty

    var errorDescription: String? { "The file has no audio in it." }
  }

  /// Reads an audio file (up to a minute of it, or `maximumSeconds`, and its first two
  /// channels), saying in `notice` what was left out.
  convenience init(contentsOf url: URL, maximumSeconds: Double = SamplerSampleBuffer.maximumSeconds) throws {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length), maximumSeconds * format.sampleRate))
    guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw LoadError.empty }
    try file.read(into: buffer, frameCount: frames)
    guard let data = buffer.floatChannelData, buffer.frameLength > 1 else { throw LoadError.empty }
    let channels = (0..<min(2, Int(format.channelCount))).map { channel in
      Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
    }
    let notice = Self.notice(
      isShortened: AVAudioFramePosition(frames) < file.length, seconds: maximumSeconds, channelCount: Int(format.channelCount))
    self.init(name: url.deletingPathExtension().lastPathComponent, sampleRate: format.sampleRate, channels: channels, notice: notice)
  }

  /// What a file loses by being cut to fit: "Only the first 8 s is used.", "Only the first
  /// two of its 6 channels are used.", or both.
  static func notice(isShortened: Bool, seconds: Double, channelCount: Int) -> String? {
    let time = "the first \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    let channels = "the first two of its \(channelCount) channels"
    switch (isShortened, channelCount > 2) {
    case (true, true): return "Only \(time) and \(channels) are used."
    case (true, false): return "Only \(time) is used."
    case (false, true): return "Only \(channels) are used."
    case (false, false): return nil
    }
  }

  // MARK: - Saved state

  private enum Key {
    static let name = "name", sampleRate = "sampleRate", channelCount = "channels", audio = "audio"
  }

  /// The sample as a property list: its name, rate and audio (32-bit floats, one channel
  /// after the other).
  var state: [String: Any] {
    var audio = Data(capacity: frameCount * channels.count * MemoryLayout<Float>.size)
    for channel in channels {
      audio.append(UnsafeBufferPointer(start: channel, count: frameCount))
    }
    return [Key.name: name, Key.sampleRate: sampleRate, Key.channelCount: channels.count, Key.audio: audio]
  }

  convenience init?(state: [String: Any]) {
    guard let audio = state[Key.audio] as? Data, let sampleRate = state[Key.sampleRate] as? Double, sampleRate > 0,
      let channelCount = state[Key.channelCount] as? Int, (1...2).contains(channelCount)
    else { return nil }
    let frameCount = audio.count / MemoryLayout<Float>.size / channelCount
    guard frameCount > 1 else { return nil }
    let floats = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let channels = (0..<channelCount).map { Array(floats[($0 * frameCount)..<(($0 + 1) * frameCount)]) }
    self.init(name: state[Key.name] as? String ?? "Sample", sampleRate: sampleRate, channels: channels)
  }

  // MARK: - Analysis

  /// The loudest level in each of `count` stretches of the sample, for drawing it.
  func overview(count: Int) -> [Float] {
    guard frameCount > 0, count > 0 else { return [] }
    return (0..<count).map { index in
      let from = index * frameCount / count
      let to = max(from + 1, (index + 1) * frameCount / count)
      var peak: Float = 0
      for channel in channels {
        for frame in from..<min(to, frameCount) { peak = max(peak, abs(channel[frame])) }
      }
      return peak
    }
  }

  /// The note the sample plays, if it has a clear pitch (drums and noises don't): found by
  /// YIN over a few stretches after the loudest moment of its first second.
  func detectedRootNote() -> Int? {
    let window = 2_048
    let minimumLag = max(2, Int(sampleRate / 2_000))
    let maximumLag = Int(sampleRate / 40)
    // YIN compares the window with itself up to one past the longest lag.
    let span = window + maximumLag + 2
    guard frameCount > span else { return nil }
    // Mono, from the loudest moment on (past the attack, where the pitch has settled).
    let mono: (Int) -> Float = { frame in
      self.channels.reduce(0) { $0 + $1[frame] } / Float(self.channels.count)
    }
    // The loudest moment of the first second (a steady sound's could be anywhere, but
    // there must be room after it to measure).
    let searchEnd = min(frameCount - span, Int(sampleRate))
    var loudest = 0
    var loudestLevel: Float = 0
    for frame in stride(from: 0, to: max(1, searchEnd), by: 256) where abs(mono(frame)) > loudestLevel {
      loudestLevel = abs(mono(frame))
      loudest = frame
    }
    var pitches: [Double] = []
    for offset in [0.05, 0.15, 0.3] {
      let start = loudest + Int(offset * sampleRate)
      guard start + span <= frameCount else { break }
      let samples = (start..<(start + span)).map(mono)
      if let frequency = Self.yin(samples, window: window, lags: minimumLag...maximumLag, sampleRate: sampleRate) {
        pitches.append(69 + 12 * log2(frequency / 440))
      }
    }
    // At least two stretches must agree, or it isn't a steady pitch (one may be off where
    // the pitch is still settling, as in an 808's swoop).
    for pitch in pitches {
      let agreeing = pitches.filter { abs($0 - pitch) < 0.6 }
      if agreeing.count >= 2 { return Int((agreeing.reduce(0, +) / Double(agreeing.count)).rounded()) }
    }
    return nil
  }

  /// The fundamental frequency of a stretch of audio, or nil if it isn't clearly pitched.
  private static func yin(_ samples: [Float], window: Int, lags: ClosedRange<Int>, sampleRate: Double) -> Double? {
    guard samples.count >= window + lags.upperBound + 2 else { return nil }
    var difference = [Float](repeating: 0, count: lags.upperBound + 2)
    for lag in 1...(lags.upperBound + 1) {
      var sum: Float = 0
      for index in 0..<window {
        let delta = samples[index] - samples[index + lag]
        sum += delta * delta
      }
      difference[lag] = sum
    }
    // The cumulative mean normalized difference, then the first dip below the threshold.
    var normalized = [Float](repeating: 1, count: difference.count)
    var running: Float = 0
    for lag in 1..<difference.count {
      running += difference[lag]
      normalized[lag] = running > 0 ? difference[lag] * Float(lag) / running : 1
    }
    var lag = lags.lowerBound
    while lag < lags.upperBound {
      if normalized[lag] < 0.15 {
        while lag + 1 < lags.upperBound, normalized[lag + 1] < normalized[lag] { lag += 1 }
        // Between samples, by a parabola through the dip.
        let (a, b, c) = (normalized[lag - 1], normalized[lag], normalized[lag + 1])
        let denominator = a - 2 * b + c
        let shift = denominator != 0 ? Double(0.5 * (a - c) / denominator) : 0
        return sampleRate / (Double(lag) + shift)
      }
      lag += 1
    }
    return nil
  }
}

/// What the Sampler's window shows about its sample.
@MainActor
@Observable
final class SamplerDisplay {
  var name: String?
  var duration: Double = 0
  var channelCount = 0
  var overview: [Float] = []
  /// Why the last file couldn't be loaded.
  var error: String?
  /// What was left out of the file, when it was cut to fit (see `SamplerSampleBuffer.notice`).
  var notice: String?
}
