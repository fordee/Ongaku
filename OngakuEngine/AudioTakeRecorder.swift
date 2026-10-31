//
//  AudioTakeRecorder.swift
//  OngakuEngine
//

import AVFAudio
import Foundation
import OngakuCore
import Synchronization

/// Writes one audio track's take to a file while recording.
///
/// The input tap hands each buffer over with its playback time; the recorder picks the
/// track's input channels, drops anything from before the transport started, and appends the
/// rest to a file (24-bit CAF unless the recording options say otherwise; the type follows
/// the URL's extension). All file writing happens on a background queue, never on the tap's
/// thread.
final class AudioTakeRecorder: @unchecked Sendable {
  let trackID: Track.ID
  let url: URL
  let format: AVAudioFormat

  private let file: AVAudioFile
  private let input: AudioInputSelection
  private let queue = DispatchQueue(label: "Ongaku.AudioTakeRecorder", qos: .userInitiated)
  /// Playback time of the first frame written, once known. Only touched on `queue`.
  private var firstFrameTime: Double?
  private var framesWritten: AVAudioFramePosition = 0
  private var writeError: (any Error)?

  init(
    trackID: Track.ID, url: URL, input: AudioInputSelection, hardwareChannelCount: Int, sampleRate: Double,
    bitDepth: RecordingBitDepth = .int24
  ) throws {
    self.trackID = trackID
    self.url = url
    // Clamp the selection to the channels the device actually has.
    let channelCount = min(input.channelCount, max(hardwareChannelCount, 1))
    let firstChannel = min(input.firstChannel, max(hardwareChannelCount - channelCount, 0))
    self.input = AudioInputSelection(firstChannel: firstChannel, isStereo: channelCount == 2)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount)) else {
      throw CocoaError(.fileWriteUnknown)
    }
    self.format = format
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: bitDepth.rawValue,
      AVLinearPCMIsFloatKey: bitDepth == .float32,
      // AIFF stores samples big-endian.
      AVLinearPCMIsBigEndianKey: url.pathExtension == RecordingFileType.aiff.pathExtension,
    ]
    file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
  }

  /// How many leading frames of a buffer to drop because they were captured before the
  /// transport started (negative playback time).
  static func framesToDrop(bufferPlaybackTime: Double, sampleRate: Double, frameCount: Int) -> Int {
    guard bufferPlaybackTime < 0 else { return 0 }
    return min(frameCount, Int((-bufferPlaybackTime * sampleRate).rounded()))
  }

  /// Queues a captured buffer. `playbackTime` is when its first frame was heard, in seconds
  /// of playback time, already corrected for input latency.
  func append(_ buffer: AVReadOnlyAudioPCMBuffer, playbackTime: Double) {
    queue.async { [self] in
      guard writeError == nil else { return }
      let frameCount = Int(buffer.frameLength)
      let drop = Self.framesToDrop(bufferPlaybackTime: playbackTime, sampleRate: format.sampleRate, frameCount: frameCount)
      let keep = frameCount - drop
      guard keep > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep)),
        let destination = output.floatChannelData
      else { return }
      output.frameLength = AVAudioFrameCount(keep)

      for channel in 0..<Int(format.channelCount) {
        let sourceChannel = min(input.firstChannel + channel, Int(buffer.format.channelCount) - 1)
        guard case .float(let samples) = buffer.channelData(sourceChannel) else { continue }
        samples.withUnsafeBufferPointer { source in
          guard let base = source.baseAddress, source.count >= frameCount else { return }
          destination[channel].update(from: base + drop, count: keep)
        }
      }
      if firstFrameTime == nil {
        firstFrameTime = max(0, playbackTime)
      }
      do {
        try file.write(from: output)
        framesWritten += AVAudioFramePosition(keep)
      } catch {
        writeError = error
      }
    }
  }

  struct Take {
    var frameCount: AVAudioFramePosition
    /// Playback time of the take's first frame.
    var startTime: Double
  }

  /// Waits for pending writes, closes the file and describes what was recorded.
  func finish() throws -> Take? {
    try queue.sync {
      if let writeError { throw writeError }
      file.close()
      guard framesWritten > 0, let firstFrameTime else { return nil }
      return Take(frameCount: framesWritten, startTime: firstFrameTime)
    }
  }
}

/// MIDI heard while recording, with host times, collected from CoreMIDI's thread.
final class MIDICapture: Sendable {
  private let events = Mutex<[(hostTime: UInt64, bytes: [UInt8])]>([])

  func receive(_ bytes: [UInt8], atHostTime hostTime: UInt64) {
    events.withLock { $0.append((hostTime, bytes)) }
  }

  func takeEvents() -> [(hostTime: UInt64, bytes: [UInt8])] {
    events.withLock { events in
      defer { events = [] }
      return events.sorted { $0.hostTime < $1.hostTime }
    }
  }
}
