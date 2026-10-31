//
//  AutomationRenderTests.swift
//  OngakuTests
//

import AVFAudio
import AudioToolbox
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Bounces a steady tone through automated channel strips and measures the result, so the
/// engine's automation is checked sample for sample without anything being heard.
@MainActor
@Suite(.serialized)
struct AutomationRenderTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "AutomationRenderTests-\(UUID().uuidString)")
  private let rate = 48_000.0

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// Two seconds of a 1 kHz tone at 0.5 (-6 dBFS), on an audio track from the start.
  private func toneProject(_ configure: (inout Track) -> Void) throws -> (Project, URL) {
    let frames = 96_000
    let url = folder.appending(path: "Tone.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<2 {
      for frame in 0..<frames {
        buffer.floatChannelData![channel][frame] = 0.5 * cos(2 * .pi * 1_000 * Float(frame) / Float(rate))
      }
    }
    try file.write(from: buffer)
    let reference = AudioFileReference(fileName: url.lastPathComponent, sampleRate: rate, channelCount: 2, frameCount: Int64(frames))
    var track = Track(name: "Tone", kind: .audio, regions: [Region.audio(for: reference, at: .zero, tempoMap: TempoMap())])
    configure(&track)
    return (Project(tracks: [track], audioFiles: [reference]), url)
  }

  private func bounce(_ project: Project, locate url: URL) async throws -> (left: [Float], right: [Float]) {
    let output = folder.appending(path: "Bounce \(UUID().uuidString).wav")
    _ = try await ProjectBouncer(project: project) { _ in url }
      .bounce(project.bounceRange!, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false), to: output)
    let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    return (
      Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)),
      Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)))
  }

  /// The tone's level in dBFS over one 1 kHz cycle around a time.
  private func level(_ samples: [Float], at seconds: Double) -> Double {
    let center = Int(seconds * rate)
    let peak = samples[(center - 24)..<(center + 24)].map(abs).max() ?? 0
    return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
  }

  private func point(_ beats: Double, _ value: Double) -> AutomationPoint {
    AutomationPoint(position: .quarterNotes(beats), value: value)
  }

  @Test func volumeAutomationFadesTheTrack() async throws {
    // 0 dB to -20 dB over the first second (two beats at 120 BPM), then held.
    let (project, url) = try toneProject {
      $0.automation = [AutomationLane(parameter: .volume, points: [point(0, 0), point(2, -20)])]
    }
    let (left, _) = try await bounce(project, locate: url)
    let tone = 20 * log10(0.5)
    for (seconds, expected) in [(0.1, -2.0), (0.25, -5.0), (0.5, -10.0), (0.75, -15.0), (1.5, -20.0)] {
      let measured = level(left, at: seconds) - tone
      #expect(abs(measured - expected) < 0.25, "At \(seconds) s: \(measured) dB, expected \(expected)")
    }
  }

  @Test func automationAppliesFromTheFirstSample() async throws {
    let (project, url) = try toneProject {
      $0.automation = [AutomationLane(parameter: .volume, points: [point(0, -12)])]
    }
    let (left, _) = try await bounce(project, locate: url)
    #expect(abs(Double(abs(left[0])) - 0.5 * pow(10, -12.0 / 20)) < 0.001)
  }

  @Test func panAutomationMovesTheTrack() async throws {
    // From centre to hard left over the first second.
    let (project, url) = try toneProject {
      $0.automation = [AutomationLane(parameter: .pan, points: [point(0, 0), point(2, -1)])]
    }
    let (left, right) = try await bounce(project, locate: url)
    #expect(abs(level(left, at: 0.1) - level(right, at: 0.1)) < 1, "Starts in the centre")
    #expect(level(right, at: 1.5) < -60, "Ends hard left")
    #expect(abs(level(left, at: 1.5) - 20 * log10(0.5)) < 0.25)
  }

  @Test func sendAutomationFadesTheSend() async throws {
    // The tone is only heard through a pre-fader send to an aux, faded 0 dB to -20 dB.
    let aux = Track(name: "Aux", kind: .aux)
    var (project, url) = try toneProject { track in
      track.channel.volume = ChannelStrip.volumeRange.lowerBound
      let send = Send(destinationTrackID: aux.id, level: 0, isPreFader: true)
      track.channel.sends = [send]
      track.automation = [AutomationLane(parameter: .sendLevel(send.id), points: [point(0, 0), point(2, -20)])]
    }
    project.tracks.append(aux)
    let (left, _) = try await bounce(project, locate: url)
    let tone = 20 * log10(0.5)
    for (seconds, expected) in [(0.1, -2.0), (0.5, -10.0), (1.5, -20.0)] {
      let measured = level(left, at: seconds) - tone
      #expect(abs(measured - expected) < 0.5, "At \(seconds) s: \(measured) dB, expected \(expected)")
    }
  }

  @Test func pluginAutomationDrivesTheInsert() async throws {
    // The Limiter's pre-gain (-40…+40 dB) from 0 dB (half way) down to -10 dB over a second.
    var insert: PluginReference?
    let (project, url) = try toneProject { track in
      let limiter = BuiltInEffect.limiter.makeReference()
      insert = limiter
      track.channel.inserts = [limiter]
      let preGain = PluginParameter(pluginID: limiter.id, address: AUParameterAddress(kLimiterParam_PreGain), name: "Pre-Gain")
      track.automation = [AutomationLane(parameter: .plugin(preGain), points: [point(0, 0.5), point(2, 0.375)])]
    }
    #expect(insert != nil)
    let (left, _) = try await bounce(project, locate: url)
    let start = level(left, at: 0.1)
    let end = level(left, at: 1.5)
    #expect(abs(end - start + 10) < 1, "The insert's gain followed the automation (\(start) → \(end) dB)")
  }

  @Test func offModeIgnoresAutomation() async throws {
    let (project, url) = try toneProject {
      $0.channel.volume = -6
      $0.automationMode = .off
      $0.automation = [AutomationLane(parameter: .volume, points: [point(0, -40)])]
    }
    let (left, _) = try await bounce(project, locate: url)
    #expect(abs(level(left, at: 1) - (20 * log10(0.5) - 6)) < 0.25, "The fader setting, not the automation")
  }

  @Test func muteStillWinsOverAutomation() async throws {
    let (project, url) = try toneProject {
      $0.channel.isMuted = true
      $0.automation = [AutomationLane(parameter: .volume, points: [point(0, 0)])]
    }
    let (left, _) = try await bounce(project, locate: url)
    #expect(left.allSatisfy { $0 == 0 })
  }

  /// Players used to read files in the background, and a render running faster than real
  /// time could get ahead of them: every bounce after the first in a session started with a
  /// silent block.
  @Test func repeatedBouncesStartOnTheFirstSample() async throws {
    let (project, url) = try toneProject { _ in }
    for _ in 0..<3 {
      let (left, _) = try await bounce(project, locate: url)
      #expect(abs(left[0] - 0.5) < 0.0001)
      // Every 1 kHz cycle (48 samples) of the first two render blocks is at full level.
      let quietCycles = stride(from: 0, to: 8_160, by: 48).filter { start in
        (left[start..<(start + 48)].map(abs).max() ?? 0) < 0.49
      }
      #expect(quietCycles.isEmpty, "Quiet cycles start at samples \(quietCycles.prefix(4))")
    }
  }

  // MARK: - Queue

  @Test func theQueueHandsEachBufferItsPartOfARamp() {
    let queue = AutomationQueue(address: 7)
    queue.push(.init(start: 100, end: 300, from: 0, to: 1))
    queue.push(.init(start: 300, end: 400, from: 1, to: 1))
    var events: [(time: Int64, duration: UInt32, value: Float)] = []
    let schedule: AUScheduleParameterBlock = { time, duration, _, value in events.append((Int64(time), duration, value)) }

    queue.deliver(bufferStart: 0, frameCount: 200, to: schedule)
    #expect(events.map(\.time) == [100, 100])
    #expect(events.map(\.duration) == [0, 100])
    #expect(events.map(\.value) == [0, 0.5])

    events = []
    queue.deliver(bufferStart: 200, frameCount: 200, to: schedule)
    #expect(events.map(\.time) == [200, 200, 300, 300])
    #expect(events.map(\.value) == [0.5, 1, 1, 1])

    events = []
    queue.isSuspended = true
    queue.push(.init(start: 400, end: 500, from: 0, to: 0))
    queue.deliver(bufferStart: 400, frameCount: 100, to: schedule)
    #expect(events.isEmpty, "Suspended while a control is held")

    queue.isSuspended = false
    queue.push(.init(start: 600, end: 700, from: 0, to: 0))
    queue.flush()
    queue.deliver(bufferStart: 600, frameCount: 100, to: schedule)
    #expect(events.isEmpty, "Flushed when the transport stops")
  }
}
