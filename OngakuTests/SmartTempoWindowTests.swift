//
//  SmartTempoWindowTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

/// Smart Tempo from the window: a 100 BPM recording found, then matched to a 120 BPM song.
@MainActor
@Suite(.serialized)
struct SmartTempoWindowTests {
  private let rate = 48_000.0

  /// Eight seconds of clicks at 100 BPM (accented beats, quieter off-beats), from 0.2 s.
  private func clickFile(in folder: URL) throws -> URL {
    let url = folder.appending(path: "Loop.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let frames = Int(8 * rate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    var time = 0.2
    var beat = 0
    while time < 8 {
      let start = Int(time * rate)
      let level: Float = beat % 2 == 0 ? 0.8 : 0.3
      for index in 0..<240 where start + index < frames {
        buffer.floatChannelData![0][start + index] = level * sin(2 * .pi * 1_500 * Float(index) / Float(rate)) * (1 - Float(index) / 240)
      }
      time += 0.3
      beat += 1
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    return url
  }

  @Test func aRecordingIsMatchedToTheSong() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SmartTempoWindowTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let document = OngakuDocument(project: Project(tracks: []))
    let window = ProjectWindowModel(document: document)
    let file = try await document.stageAudio(from: try clickFile(in: folder))
    let region = Region.audio(for: file, at: .zero, tempoMap: TempoMap())
    window.perform(CompositeCommand("Setup", commands: [AddAudioFile(file), AddTrack(Track(name: "Loop", kind: .audio, regions: [region]))]))

    window.detectTempo(of: region.id)
    for _ in 0..<100 where window.detectedTempos[region.id] == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    let tempo = try #require(window.detectedTempos[region.id])
    #expect(abs(tempo.bpm - 100) < 0.5)

    window.matchProjectTempo(region.id)
    window.projectDidChange()
    for task in window.flexRenderTasks.values { await task.value }
    #expect(window.flexRenders.count == 1, "The stretched region is rendered")

    // Bounced, the accented clicks are now a beat (0.5 s at 120 BPM) apart instead of 0.6 s.
    let project = window.projectWithCurrentPluginStates()
    let output = folder.appending(path: "Bounce.caf")
    _ = try await ProjectBouncer(project: project) { [weak document] in document?.url(for: $0) }
      .bounce(try #require(project.bounceRange), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false), to: output)
    let bounced = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: bounced.processingFormat, frameCapacity: AVAudioFrameCount(bounced.length)))
    try bounced.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let found = try #require(TempoDetector.detect(samples, sampleRate: rate))
    #expect(abs(found.bpm - 120) < 1, "The bounced loop plays at \(found.bpm) BPM")
  }
}
