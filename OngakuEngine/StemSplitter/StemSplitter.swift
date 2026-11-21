//
//  StemSplitter.swift
//  OngakuEngine
//

import AVFAudio
import Foundation

/// Splits a recording into stems (drums, bass, other, vocals) with HTDemucs, as Logic's Stem
/// Splitter does: the audio at 44.1 kHz stereo, in 7.8-second segments overlapping by a
/// quarter and cross-faded (as Demucs's `apply_model`), each stem written to its own file at
/// the recording's own rate.
public enum StemSplitter {
  /// The stems, in the order the model gives them.
  public static let stemNames = ["Drums", "Bass", "Other", "Vocals"]

  public enum SplitError: LocalizedError {
    case noModel
    case unreadable(String)

    public var errorDescription: String? {
      switch self {
      case .noModel: "The Stem Splitter's model isn't installed with the app."
      case .unreadable(let detail): "The recording couldn't be read: \(detail)."
      }
    }
  }

  /// One stem written to a file.
  public struct Stem: Sendable {
    public var name: String
    public var url: URL
  }

  /// The model, loaded once and kept (it takes a moment to read).
  private static let cache = ModelCache()

  /// Splits part of an audio file: `frames` frames from `startFrame` (the file's own rate).
  /// `progress` goes from 0 to 1. Throws `CancellationError` when the task is cancelled.
  public static func split(
    fileAt url: URL, startFrame: Int64, frames: Int64, model modelURL: URL?, into folder: URL, baseName: String,
    progress: @Sendable (Double) -> Void = { _ in }
  ) async throws -> [Stem] {
    guard let modelURL else { throw SplitError.noModel }
    let model = try await cache.model(at: modelURL)
    try Task.checkCancellation()

    // The audio, at 44.1 kHz stereo.
    let source: AVAudioFile
    do {
      source = try AVAudioFile(forReading: url)
    } catch {
      throw SplitError.unreadable(error.localizedDescription)
    }
    let originalRate = source.processingFormat.sampleRate
    let count = AVAudioFrameCount(max(0, min(frames, source.length - startFrame)))
    guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else {
      throw SplitError.unreadable("the region has no audio")
    }
    source.framePosition = startFrame
    try source.read(into: buffer, frameCount: count)
    let (left, right) = try resampled(buffer, to: HTDemucs.sampleRate)
    progress(0.02)

    // Overlapping segments, cross-faded with a triangle.
    let length = left.count
    let segment = model.segmentLength
    let stride = Int(0.75 * Double(segment))
    let weight: [Float] = {
      let half = segment / 2
      let rising = (1...half).map(Float.init)
      let falling = Swift.stride(from: segment - half, to: 0, by: -1).map(Float.init)
      let all = rising + falling
      let maximum = all.max() ?? 1
      return all.map { $0 / maximum }
    }()
    var sums = [Float](repeating: 0, count: length)
    var stems = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: HTDemucs.sources.count)
    let offsets = Array(Swift.stride(from: 0, to: length, by: stride))
    for (index, offset) in offsets.enumerated() {
      try Task.checkCancellation()
      let end = min(length, offset + segment)
      let separated = model.separate(left: Array(left[offset..<end]), right: Array(right[offset..<end]))
      for i in 0..<(end - offset) {
        let w = weight[i]
        sums[offset + i] += w
        for s in 0..<separated.count {
          stems[s][0][offset + i] += w * separated[s][0][i]
          stems[s][1][offset + i] += w * separated[s][1][i]
        }
      }
      progress(0.02 + 0.93 * Double(index + 1) / Double(offsets.count))
    }
    for s in stems.indices {
      for c in 0..<2 {
        for i in 0..<length where sums[i] > 0 { stems[s][c][i] /= sums[i] }
      }
    }

    // Each stem to a file, back at the recording's rate.
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var written: [Stem] = []
    for (s, name) in stemNames.enumerated() {
      try Task.checkCancellation()
      let destination = folder.appending(path: "\(baseName) – \(name).wav")
      try write(left: stems[s][0], right: stems[s][1], rate: HTDemucs.sampleRate, as: originalRate, to: destination)
      written.append(Stem(name: name, url: destination))
    }
    progress(1)
    return written
  }

  /// A buffer as two float arrays at `rate` (mono is doubled).
  static func resampled(_ buffer: AVAudioPCMBuffer, to rate: Double) throws -> ([Float], [Float]) {
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
      let converter = AVAudioConverter(from: buffer.format, to: target)
    else { throw SplitError.unreadable("its format isn't supported") }
    if buffer.format.channelCount == 1 { converter.channelMap = [0, 0] }
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SplitError.unreadable("out of memory") }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if supplied {
        outStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return buffer
    }
    if status == .error { throw SplitError.unreadable(error?.localizedDescription ?? "conversion failed") }
    let frames = Int(output.frameLength)
    let left = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: frames))
    let right = Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: frames))
    return (left, right)
  }

  /// Writes a stereo stem as a 32-bit float WAV file at `outputRate`.
  static func write(left: [Float], right: [Float], rate: Double, as outputRate: Double, to url: URL) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(left.count)
    left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
    right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
    var data = buffer
    if outputRate != rate {
      let (convertedLeft, convertedRight) = try resampled(buffer, to: outputRate)
      guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 2, interleaved: false),
        let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(convertedLeft.count))
      else { return }
      converted.frameLength = AVAudioFrameCount(convertedLeft.count)
      convertedLeft.withUnsafeBufferPointer { converted.floatChannelData![0].update(from: $0.baseAddress!, count: convertedLeft.count) }
      convertedRight.withUnsafeBufferPointer { converted.floatChannelData![1].update(from: $0.baseAddress!, count: convertedRight.count) }
      data = converted
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: data.format.sampleRate, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: data)
    file.close()
  }

  /// Keeps the model loaded between splits.
  private actor ModelCache {
    private var loaded: (url: URL, model: HTDemucs)?

    func model(at url: URL) async throws -> HTDemucs {
      if let loaded, loaded.url == url { return loaded.model }
      let model = try await Task.detached(priority: .userInitiated) { try HTDemucs(checkpoint: url) }.value
      loaded = (url, model)
      return model
    }
  }
}
