//
//  PerformanceTests.swift
//  OngakuTests
//

import AVFAudio
import AppKit
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import SwiftUI
import Testing

/// Measures Ongaku with a large generated song (100 tracks, ~1,000 regions, ~40,000 notes,
/// automation on every track). Results are printed as `PERF` lines; the expectations are
/// loose ceilings that only catch something badly wrong.
///
/// Nothing here touches the screen or the speakers: playback runs with Stereo Out at -∞,
/// and views are measured in a window that is never shown.
@MainActor
@Suite(.serialized)
struct PerformanceTests {
  private static let folder = FileManager.default.temporaryDirectory.appending(path: "OngakuPerformance")

  // MARK: - Fixtures

  /// Four 8-second tone files for the audio tracks.
  private static func toneFiles() throws -> [(URL, AudioFileReference)] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try (0..<4).map { index in
      let url = folder.appending(path: "Tone \(index).caf")
      let frames = 48_000 * 8
      let reference = AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 2, frameCount: Int64(frames))
      guard !FileManager.default.fileExists(atPath: url.path) else { return (url, reference) }
      let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      let frequency = Float(110 * (index + 1))
      for channel in 0..<2 {
        for frame in 0..<frames {
          // A tone with a slow swell, so waveforms have shape.
          let envelope = 0.3 + 0.3 * sin(Float(frame) / 48_000 * .pi)
          buffer.floatChannelData![channel][frame] = envelope * sin(2 * .pi * frequency * Float(frame) / 48_000)
        }
      }
      try file.write(from: buffer)
      return (url, reference)
    }
  }

  private static func stressProject() throws -> (Project, [AudioFileReference.ID: URL]) {
    let tones = try toneFiles()
    var project = StressTestProject.make(audioFiles: tones.map(\.1))
    // Silent: everything renders, nothing is heard.
    project.masterVolume = ChannelStrip.volumeRange.lowerBound
    return (project, Dictionary(uniqueKeysWithValues: tones.map { ($0.1.id, $0.0) }))
  }

  private func time<T>(_ body: () throws -> T) rethrows -> (T, Duration) {
    let clock = ContinuousClock()
    var result: T!
    let duration = try clock.measure { result = try body() }
    return (result, duration)
  }

  private func ms(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return value.formatted(.number.precision(.fractionLength(2))) + " ms"
  }

  private func report(_ name: String, _ value: String) {
    print("PERF \(name): \(value)")
  }

  /// CPU time used by this process so far (all threads, including audio rendering).
  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }

  // MARK: - Model

  @Test func modelCosts() throws {
    let (stress, generateTime) = try time { try Self.stressProject() }
    let generated = stress.0
    let regionCount = generated.tracks.map(\.regions.count).reduce(0, +)
    let noteCount = generated.tracks.flatMap(\.regions).map { region -> Int in
      if case .midi(let sequence) = region.content { sequence.notes.count } else { 0 }
    }.reduce(0, +)
    report("song", "\(generated.tracks.count) tracks, \(regionCount) regions, \(noteCount) notes")
    report("generate", ms(generateTime))

    let (data, encodeTime) = try time { try ProjectArchive.encode(generated) }
    let (_, decodeTime) = try time { try ProjectArchive.decode(data) }
    report("save (encode)", "\(ms(encodeTime)) for \(data.count / 1024) KB")
    report("open (decode)", ms(decodeTime))

    // An everyday edit: mute a track. Snapshot undo copies the project each time.
    let editor = ProjectEditor(project: generated)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    var editTimes: [Duration] = []
    for index in 0..<20 {
      let track = editor.project.tracks[index]
      var channel = track.channel
      channel.isMuted.toggle()
      undoManager.beginUndoGrouping()
      let (_, duration) = try time { try editor.perform(SetChannelStrip(track.id, to: channel, actionName: "Mute"), undoManager: undoManager) }
      undoManager.endUndoGrouping()
      editTimes.append(duration)
    }
    report("edit (mute a track)", "avg \(ms(editTimes.reduce(.zero, +) / editTimes.count)), max \(ms(editTimes.max()!))")
    let (_, undoTime) = time { undoManager.undo() }
    report("undo", ms(undoTime))

    // What the engine asks the plan for every two seconds of playback.
    let plan = PlaybackPlan(project: generated, startPosition: .zero)
    var windowTimes: [Duration] = []
    var start = 0.0
    while start < 120 {
      let window = start..<(start + 2)
      let (_, duration) = time {
        _ = plan.audioSegments(startingIn: window)
        _ = plan.midiEvents(in: window)
        _ = plan.automationRamps(in: window)
      }
      windowTimes.append(duration)
      start += 2
    }
    report("plan per 2 s window", "avg \(ms(windowTimes.reduce(.zero, +) / windowTimes.count)), max \(ms(windowTimes.max()!))")
    #expect(windowTimes.max()! < .milliseconds(500))
  }

  // MARK: - Engine

  @Test func engineSetupAndUpdates() throws {
    let (project, urls) = try Self.stressProject()
    let (engine, setupTime) = time { PlaybackEngine(project: project) { urls[$0.id] } }
    defer { engine.shutDown() }
    report("engine setup (100 channels)", "\(ms(setupTime)), \(engine.engine.attachedNodes.count) nodes")
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")

    // A mixer change and an arrangement change, as the window sends after each edit.
    var updated = project
    var mixTimes: [Duration] = []
    for index in 0..<10 {
      updated.tracks[index].channel.volume -= 1
      let snapshot = updated
      mixTimes.append(time { engine.update(project: snapshot) }.1)
    }
    report("engine update (fader edit)", "avg \(ms(mixTimes.reduce(.zero, +) / mixTimes.count)), max \(ms(mixTimes.max()!))")

    updated.tracks[0].regions[0].start += .quarterNotes(1)
    let moved = updated
    report("engine update (region moved)", ms(time { engine.update(project: moved) }.1))

    // Moving the playhead while stopped also sets every automated control to its value there.
    var locateTimes: [Duration] = []
    for step in 0..<30 {
      locateTimes.append(time { engine.locate(to: .quarterNotes(Double(step) * 0.25)) }.1)
    }
    report("engine locate while stopped (no drawing)", "avg \(ms(locateTimes.reduce(.zero, +) / locateTimes.count))")
  }

  @Test func livePlaybackCPU() async throws {
    let (project, urls) = try Self.stressProject()
    let engine = PlaybackEngine(project: project) { urls[$0.id] }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(500))

    let clock = ContinuousClock()
    let cpuBefore = cpuSeconds()
    let wallStart = clock.now
    report("engine play (start from stopped)", ms(time { engine.play() }.1))
    #expect(engine.isPlaying, "\(engine.lastError ?? "")")

    // While it plays, see how late the main thread wakes up: the scheduler, meters and
    // playhead all run there.
    var lateness: [Duration] = []
    while clock.now - wallStart < .seconds(10) {
      let asleep = clock.now
      try await Task.sleep(for: .milliseconds(10))
      lateness.append(clock.now - asleep - .milliseconds(10))
    }
    let wall = clock.now - wallStart
    let cpu = cpuSeconds() - cpuBefore
    // Moving the playhead while playing restarts playback from there.
    var relocateTimes: [Duration] = []
    for step in 0..<5 {
      relocateTimes.append(time { engine.locate(to: .quarterNotes(Double(step) * 16)) }.1)
      try await Task.sleep(for: .milliseconds(200))
    }
    report("engine locate while playing", relocateTimes.map(ms).joined(separator: ", "))
    report("engine stop", ms(time { engine.stop() }.1))
    let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
    let sorted = lateness.sorted()
    report("live playback CPU", "\(Int((cpu / wallSeconds * 100).rounded()))% of one core over \(Int(wallSeconds)) s")
    report("main thread lateness", "median \(ms(sorted[sorted.count / 2])), p99 \(ms(sorted[sorted.count * 99 / 100])), max \(ms(sorted.last!))")
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")
  }

  @Test func bounceSpeed() async throws {
    let (project, urls) = try Self.stressProject()
    // The first 32 bars (64 s at 120 BPM).
    let range = Tick.zero..<Tick.quarterNotes(128)
    let output = Self.folder.appending(path: "Stress bounce.wav")
    let clock = ContinuousClock()
    let started = clock.now
    let result = try await ProjectBouncer(project: project) { urls[$0.id] }
      .bounce(range, settings: BounceSettings(includeTail: false), to: output)
    let elapsed = clock.now - started
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    report("bounce 64 s of the song", "\(ms(elapsed)) (\((result.duration / seconds).formatted(.number.precision(.fractionLength(1))))× real time)")
  }
}
