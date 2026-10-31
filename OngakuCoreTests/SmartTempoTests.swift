//
//  SmartTempoTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Smart Tempo: finding a recording's tempo, and the song or the recording following the
/// other.
struct SmartTempoTests {
  private let rate = 48_000.0

  /// A click every beat at `bpm`, the first at `offset` seconds, with quieter clicks on the
  /// off-beats (so the tempo isn't simply the click rate).
  private func clickTrack(bpm: Double, offset: Double, seconds: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    let period = 60 / bpm
    var time = offset
    var beat = 0
    while time < seconds {
      let start = Int(time * rate)
      let level: Float = beat % 2 == 0 ? 0.8 : 0.3
      for index in 0..<240 where start + index < samples.count {
        samples[start + index] = level * sin(2 * .pi * 1_500 * Float(index) / Float(rate)) * (1 - Float(index) / 240)
      }
      time += period / 2
      beat += 1
    }
    return samples
  }

  @Test(arguments: [(100.0, 0.3), (92.0, 0.1), (128.0, 0.45), (75.0, 0.2)])
  func tempoIsFound(bpm: Double, offset: Double) throws {
    let tempo = try #require(TempoDetector.detect(clickTrack(bpm: bpm, offset: offset, seconds: 12), sampleRate: rate))
    #expect(abs(tempo.bpm - bpm) < 0.5, "Found \(tempo.bpm) BPM for \(bpm)")
    // The first beat is the offset, or a whole beat later (a beat is a beat).
    let phase = (tempo.firstBeat - offset).truncatingRemainder(dividingBy: tempo.period / 2)
    #expect(min(abs(phase), tempo.period / 2 - abs(phase)) < 0.015, "First beat at \(tempo.firstBeat) s for \(offset) s")
  }

  @Test func silenceHasNoTempo() {
    #expect(TempoDetector.detect([Float](repeating: 0, count: 48_000 * 5), sampleRate: rate) == nil)
  }

  /// A 6 s audio region at bar 2 (2 s in at 120 BPM).
  private func project() -> (Project, Region) {
    let file = AudioFileReference(fileName: "Loop.caf", sampleRate: rate, channelCount: 1, frameCount: 288_000)
    let region = Region(
      name: "Loop", start: .quarterNotes(4), length: .quarterNotes(12), content: .audio(AudioRegionContent(fileID: file.id)))
    return (Project(tracks: [Track(name: "Loop", kind: .audio, regions: [region])], audioFiles: [file]), region)
  }

  @Test func adaptingSetsTheSongsTempoAndLinesUpTheFirstBeat() throws {
    var (project, region) = project()
    let tempo = DetectedTempo(bpm: 100, firstBeat: 0.25, confidence: 1)
    try AdaptProjectTempo(to: tempo, of: region.id).apply(to: &project)
    #expect(project.tempoMap.tempo(at: .zero) == 100)
    let adapted = try #require(project.region(withID: region.id))
    // The first beat lands on a beat line.
    let beatPosition = project.tempoMap.tickPosition(atSeconds: project.tempoMap.seconds(at: adapted.start) + 0.25)
    #expect(beatPosition.rawValue % 960 <= 1 || beatPosition.rawValue % 960 >= 959)
    #expect(abs(project.duration(of: adapted) - 6) < 0.001, "Still all six seconds of audio")
  }

  @Test func matchingStretchesTheRecordingToTheSong() throws {
    var (project, region) = project()
    // The loop is at 100 BPM; the song is at 120.
    try MatchProjectTempo(region.id, from: DetectedTempo(bpm: 100, firstBeat: 0, confidence: 1)).apply(to: &project)
    let matched = try #require(project.region(withID: region.id))
    guard case .audio(let audio) = matched.content else { Issue.record("Not audio"); return }
    #expect(abs(audio.stretch - 1.2) < 1e-9)
    #expect(abs(project.duration(of: matched) - 5) < 0.001, "Six seconds of audio played 1.2 times faster")
    #expect(matched.start == .quarterNotes(4), "Its first beat was already on a beat")

    let key = try #require(project.flexRenderKey(for: matched, on: project.tracks[0]))
    #expect(key.mode == .rhythmic)
    #expect(key.frameCount == 240_000)
    #expect(key.sourceFrameCount == 288_000)

    try ResetRegionStretch(region.id).apply(to: &project)
    #expect(abs(project.duration(of: project.tracks[0].regions[0]) - 6) < 0.001)
  }

  @Test func stretchedMapsPlayMoreOfTheRecording() {
    let map = FlexMap(markers: [], duration: 5, sourceDuration: 6)
    #expect(map.sourceTime(atTarget: 2.5) == 3)
    #expect(map.sourceTime(atTarget: 5) == 6)
    // Stretching a click track by 1.2 puts each click 1.2 times sooner.
    let clicks = clickTrack(bpm: 60, offset: 0, seconds: 6)
    let rendered = FlexRenderer.render([clicks], map: map, mode: .rhythmic, sampleRate: rate)[0]
    #expect(rendered.count == 240_000)
  }
}
