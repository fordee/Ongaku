//
//  AudioPlaybackSyncTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Synchronization
import Testing

/// Live playback with many audio tracks: everything must start on the same sample, and the
/// transport must never make the main thread wait for the audio thread.
@MainActor
@Suite(.serialized)
struct AudioPlaybackSyncTests {
  private static let trackCount = 32

  /// Writes a file of silence with a short, quiet burst `burstAt` seconds in.
  private func makeFile(rate: Double, channels: AVAudioChannelCount = 2, seconds: Double = 2, burstAt: Double?) throws -> (URL, AudioFileReference) {
    let url = FileManager.default.temporaryDirectory.appending(path: "AudioPlaybackSyncTests-\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
      buffer.floatChannelData![channel].update(repeating: 0, count: Int(frames))
      if let burstAt {
        let start = Int(burstAt * rate)
        for frame in start..<(start + 64) {
          buffer.floatChannelData![channel][frame] = 0.05
        }
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return (url, AudioFileReference(fileName: url.lastPathComponent, sampleRate: rate, channelCount: Int(channels), frameCount: Int64(frames)))
  }

  /// A project of `trackCount` audio tracks: the first panned hard left plays `left`, the
  /// last panned hard right plays `right`, and the rest play silence.
  private func makeProject(left: AudioFileReference, right: AudioFileReference, silence: AudioFileReference) -> Project {
    var tracks: [Track] = []
    for index in 0..<Self.trackCount {
      let file = index == 0 ? left : index == Self.trackCount - 1 ? right : silence
      var track = Track(name: "Audio \(index + 1)", kind: .audio, regions: [Region.audio(for: file, at: .zero, tempoMap: TempoMap())])
      if index == 0 { track.channel.pan = -1 }
      if index == Self.trackCount - 1 { track.channel.pan = 1 }
      tracks.append(track)
    }
    return Project(tracks: tracks, audioFiles: [left, right, silence])
  }

  /// Plays the project and returns where, in frames of Stereo Out's output, sound first
  /// appeared on the left and on the right.
  private func firstSound(in project: Project, urls: [AudioFileReference.ID: URL]) async throws -> (left: Int?, right: Int?, engine: PlaybackEngine) {
    let engine = PlaybackEngine(project: project) { urls[$0.id] }
    try await Task.sleep(for: .milliseconds(400))  // let the engine settle

    let onsets = Onsets()
    // Stereo Out's meter already taps it, and a bus takes only one tap.
    engine.meters.stopMetering(engine.engine.mainMixerNode, as: LevelMeters.masterID)
    try engine.engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 512, format: nil, tapProvider: onsets.tapBlock())
    engine.play()
    try await Task.sleep(for: .milliseconds(1_200))
    engine.stop()
    engine.engine.mainMixerNode.removeTap(onBus: 0)
    let result = onsets.result
    return (result.left, result.right, engine)
  }

  @Test func manyAudioTracksStartTogether() async throws {
    let (burstURL, burst) = try makeFile(rate: 48_000, burstAt: 0.25)
    let (silenceURL, silence) = try makeFile(rate: 48_000, burstAt: nil)
    defer {
      try? FileManager.default.removeItem(at: burstURL)
      try? FileManager.default.removeItem(at: silenceURL)
    }
    // The same file on both sides, so any difference is the engine's.
    let project = makeProject(left: burst, right: burst, silence: silence)
    let (left, right, engine) = try await firstSound(in: project, urls: [burst.id: burstURL, silence.id: silenceURL])
    defer { engine.shutDown() }

    let leftFrame = try #require(left, "The left track should be heard")
    let rightFrame = try #require(right, "The right track should be heard")
    print("SYNC 32 tracks: left starts at frame \(leftFrame), right at \(rightFrame), missed \(engine.missedAudioFrames)")
    #expect(leftFrame == rightFrame, "First and last tracks start on the same sample (\(leftFrame) vs \(rightFrame))")
    #expect(engine.missedAudioFrames == 0, "Every chunk arrived before it was due")
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")
  }

  /// A 44.1 kHz mono file is converted to the output rate and both sides as it's read; it
  /// must still land at the same time as a file at the output rate.
  @Test func filesAtOtherRatesStayInTime() async throws {
    let probe = AVAudioEngine()
    let outputRate = probe.outputNode.outputFormat(forBus: 0).sampleRate
    let otherRate = outputRate == 44_100 ? 48_000.0 : 44_100.0
    let (nativeURL, native) = try makeFile(rate: outputRate, burstAt: 0.5)
    let (otherURL, other) = try makeFile(rate: otherRate, channels: 1, burstAt: 0.5)
    let (silenceURL, silence) = try makeFile(rate: outputRate, burstAt: nil)
    defer {
      for url in [nativeURL, otherURL, silenceURL] { try? FileManager.default.removeItem(at: url) }
    }
    let project = makeProject(left: native, right: other, silence: silence)
    let (left, right, engine) = try await firstSound(
      in: project, urls: [native.id: nativeURL, other.id: otherURL, silence.id: silenceURL])
    defer { engine.shutDown() }

    let leftFrame = try #require(left)
    let rightFrame = try #require(right)
    print("SYNC \(Int(otherRate)) Hz mono vs \(Int(outputRate)) Hz: left at frame \(leftFrame), right at \(rightFrame)")
    // Resampling smears the burst's edge by a few samples, but no more.
    #expect(abs(leftFrame - rightFrame) <= 8, "Within 8 samples (\(leftFrame) vs \(rightFrame))")
    #expect(engine.missedAudioFrames == 0)
  }

  /// Play, locate and stop only queue work, so none of them may hold up the main thread.
  @Test func transportCallsDontWaitForTheAudioThread() async throws {
    let (url, file) = try makeFile(rate: 48_000, seconds: 4, burstAt: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let project = makeProject(left: file, right: file, silence: file)
    let engine = PlaybackEngine(project: project) { _ in url }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(400))

    let clock = ContinuousClock()
    let play = clock.measure { engine.play() }
    try await Task.sleep(for: .milliseconds(300))
    let locate = clock.measure { engine.locate(to: .quarterNotes(2)) }
    try await Task.sleep(for: .milliseconds(300))
    let stop = clock.measure { engine.stop() }

    print("SYNC transport with 32 audio tracks: play \(play), locate \(locate), stop \(stop)")
    #expect(play < .milliseconds(50), "Play took \(play)")
    #expect(locate < .milliseconds(50), "Locate took \(locate)")
    #expect(stop < .milliseconds(20), "Stop took \(stop)")
    #expect(engine.missedAudioFrames == 0)
  }
}

/// Where sound first appears on each side of a tapped output. The tap block may run on any
/// thread, so it's made outside the main actor and only touches the lock-protected state.
private final class Onsets: Sendable {
  private let state = Mutex<(frames: Int, left: Int?, right: Int?)>((0, nil, nil))

  var result: (left: Int?, right: Int?) {
    state.withLock { ($0.left, $0.right) }
  }

  nonisolated func tapBlock() -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
    { [self] buffer, _ in
      guard buffer.format.channelCount == 2,
        case .float(let left) = buffer.channelData(0), case .float(let right) = buffer.channelData(1)
      else { return }
      state.withLock { state in
        for frame in 0..<min(left.count, right.count) {
          if state.left == nil, abs(left[frame]) > 0.01 { state.left = state.frames + frame }
          if state.right == nil, abs(right[frame]) > 0.01 { state.right = state.frames + frame }
        }
        state.frames += left.count
      }
    }
  }
}
