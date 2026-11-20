//
//  FlexAudio.swift
//  OngakuEngine
//

import Accelerate
import AVFAudio
import Foundation
import OngakuCore

/// Flex Time's file work: rendering a flexed region to a file, and finding transients in a
/// region's audio. Both run off the main thread.
public enum FlexAudio {
  public enum FlexError: Error, LocalizedError {
    case unreadable

    public var errorDescription: String? { "The audio couldn’t be read for Flex." }
  }

  /// Renders what a flexed region plays to a 32-bit float CAF at `destination`: the
  /// region's stretch of the source file, through its flex markers.
  @concurrent
  public static func render(
    _ key: Project.FlexRenderKey, source: URL, to destination: URL
  ) async throws -> AudioFileReference {
    let (channels, format) = try read(source, from: key.fileStartFrame, frames: key.sourceFrameCount)
    let duration = Double(key.frameCount) / format.sampleRate
    let sourceDuration = Double(key.sourceFrameCount) / format.sampleRate
    let map = FlexMap(markers: key.markers, duration: duration, sourceDuration: sourceDuration)
    let rendered = FlexRenderer.render(
      channels, map: map, mode: key.mode, pitchEdits: key.pitchEdits, transpose: key.transpose, sampleRate: format.sampleRate)
    try write(rendered, sampleRate: format.sampleRate, to: destination)
    return AudioFileReference(
      fileName: destination.lastPathComponent, sampleRate: format.sampleRate, channelCount: rendered.count,
      frameCount: Int64(rendered.first?.count ?? 0))
  }

  /// Where notes and hits start in a stretch of a file, in seconds from its start.
  @concurrent
  public static func transients(in source: URL, from startFrame: Int64, frames: Int64) async throws -> [Double] {
    let (channels, format) = try read(source, from: startFrame, frames: frames)
    var mono = [Float](repeating: 0, count: channels.first?.count ?? 0)
    for channel in channels {
      for index in mono.indices { mono[index] += channel[index] }
    }
    return TransientDetector.detect(mono, sampleRate: format.sampleRate)
  }

  /// The stretches of a file with sound in them (for Strip Silence), in seconds from the
  /// stretch's start.
  @concurrent
  public static func sounds(
    in source: URL, from startFrame: Int64, frames: Int64, settings: SilenceDetector.Settings
  ) async throws -> [Range<Double>] {
    let (channels, format) = try read(source, from: startFrame, frames: frames)
    // The loudest channel at each moment decides, so a sound in one channel counts.
    var loudest = [Float](repeating: 0, count: channels.first?.count ?? 0)
    for channel in channels {
      loudest = vDSP.maximum(loudest, vDSP.absolute(channel))
    }
    return SilenceDetector.sounds(in: loudest, sampleRate: format.sampleRate, settings: settings)
  }

  /// The notes in a stretch of a file (for Flex Pitch), with times from its start.
  @concurrent
  public static func notes(in source: URL, from startFrame: Int64, frames: Int64) async throws -> [DetectedNote] {
    let (channels, format) = try read(source, from: startFrame, frames: frames)
    var mono = [Float](repeating: 0, count: channels.first?.count ?? 0)
    for channel in channels {
      for index in mono.indices { mono[index] += channel[index] / Float(channels.count) }
    }
    return PitchDetector.notes(mono, sampleRate: format.sampleRate)
  }

  /// The tempo of a stretch of a file (for Smart Tempo), with its first beat counted from
  /// the stretch's start; `nil` if it has no steady pulse.
  @concurrent
  public static func tempo(in source: URL, from startFrame: Int64, frames: Int64) async throws -> DetectedTempo? {
    let (channels, format) = try read(source, from: startFrame, frames: frames)
    var mono = [Float](repeating: 0, count: channels.first?.count ?? 0)
    for channel in channels {
      for index in mono.indices { mono[index] += channel[index] }
    }
    return TempoDetector.detect(mono, sampleRate: format.sampleRate)
  }

  /// The Audio File Editor's edits: the whole of `source` with `edit` applied to `frames`,
  /// written to `destination` as a 32-bit float CAF of the same length.
  @concurrent
  public static func edit(
    _ source: URL, _ edit: AudioFileEdit, frames: Range<Int64>, to destination: URL
  ) async throws -> AudioFileReference {
    let length = try AVAudioFile(forReading: source).length
    var (channels, format) = try read(source, from: 0, frames: length)
    edit.apply(to: &channels, frames: Int(frames.lowerBound)..<Int(frames.upperBound))
    try write(channels, sampleRate: format.sampleRate, to: destination)
    return AudioFileReference(
      fileName: destination.lastPathComponent, sampleRate: format.sampleRate, channelCount: channels.count, frameCount: length)
  }

  /// `frames` frames of a file from `startFrame` (which may be before its start or run past
  /// its end; those parts are silent), as one array per channel.
  static func read(_ url: URL, from startFrame: Int64, frames: Int64) throws -> ([[Float]], AVAudioFormat) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    var channels = [[Float]](repeating: [Float](repeating: 0, count: Int(max(0, frames))), count: channelCount)
    let readStart = max(0, startFrame)
    let skipped = Int(readStart - startFrame)
    let available = max(0, min(frames - Int64(skipped), file.length - readStart))
    guard available > 0 else { return (channels, format) }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(available)),
      let data = buffer.floatChannelData
    else { throw FlexError.unreadable }
    file.framePosition = readStart
    // A read can stop short of what was asked for, so read until it's all in.
    var done = 0
    while done < Int(available) {
      try file.read(into: buffer, frameCount: AVAudioFrameCount(Int(available) - done))
      let count = Int(buffer.frameLength)
      guard count > 0 else { break }
      for channel in 0..<channelCount {
        for index in 0..<count {
          channels[channel][skipped + done + index] = data[channel][index]
        }
      }
      done += count
    }
    return (channels, format)
  }

  static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
    let frameCount = channels.first?.count ?? 0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(1, channels.count))),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frameCount))),
      let data = buffer.floatChannelData
    else { throw FlexError.unreadable }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    for (channel, samples) in channels.enumerated() {
      samples.withUnsafeBufferPointer { data[channel].update(from: $0.baseAddress!, count: frameCount) }
    }
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    // Closed now, not whenever it's freed, so the file is complete for whoever reads it next.
    defer { file.close() }
    try file.write(from: buffer)
  }
}
