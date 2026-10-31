//
//  FlexRenderTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

/// Flex Time end to end: rendering flexed regions to files, the window keeping them up to
/// date, and bounces playing them.
@MainActor
@Suite(.serialized)
struct FlexRenderTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "FlexRenderTests-\(UUID().uuidString)")
  private let rate = 48_000.0

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// Two seconds of stereo silence with clicks at 0.5 s and 1.5 s.
  private func clickFile() throws -> URL {
    let url = folder.appending(path: "Clicks.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = 96_000
    for channel in 0..<2 {
      for click in [24_000, 72_000] {
        for index in 0..<96 {
          buffer.floatChannelData![channel][click + index] = 0.8 * sin(2 * .pi * 2_000 * Float(index) / Float(rate))
        }
      }
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    return url
  }

  private func onset(in url: URL, after seconds: Double) throws -> Double? {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    return samples.indices.dropFirst(Int(seconds * rate)).first { abs(samples[$0]) > 0.2 }.map { Double($0) / rate }
  }

  /// The second click (1.5 s in) moved to 1.75 s.
  private let marker = FlexMarker(source: 1.5, target: 1.75)

  @Test func rendersMoveTheAudio() async throws {
    let source = try clickFile()
    let key = Project.FlexRenderKey(fileID: UUID(), fileStartFrame: 0, frameCount: 96_000, markers: [marker], mode: .slicing)
    let destination = folder.appending(path: "Render.caf")
    let render = try await FlexAudio.render(key, source: source, to: destination)
    #expect(render.frameCount == 96_000)
    #expect(render.channelCount == 2)
    let moved = try #require(try onset(in: destination, after: 1))
    #expect(abs(moved - 1.75) < 0.001)
  }

  @Test func transientsAreFoundInFiles() async throws {
    let transients = try await FlexAudio.transients(in: try clickFile(), from: 0, frames: 96_000)
    #expect(transients.count == 2)
    #expect(abs(transients[0] - 0.5) < 0.01)
  }

  /// A window with the click file on a Flex track, the second click flexed.
  private func flexedWindow(mode: FlexMode = .slicing, waitingForRenders: Bool = true) async throws -> (ProjectWindowModel, Region.ID) {
    let document = OngakuDocument(project: Project(tracks: []))
    let window = ProjectWindowModel(document: document)
    let file = try await document.stageAudio(from: try clickFile())
    var track = Track(name: "Drums", kind: .audio, flexMode: mode)
    let region = Region(
      name: "Drums", start: .zero, length: .quarterNotes(4),
      content: .audio(AudioRegionContent(fileID: file.id, flexMarkers: [marker])))
    track.regions = [region]
    window.perform(CompositeCommand("Setup", commands: [AddAudioFile(file), AddTrack(track)]))
    window.projectDidChange()
    if waitingForRenders {
      for task in window.flexRenderTasks.values { await task.value }
    }
    return (window, region.id)
  }

  @Test func theWindowRendersFlexedRegionsAndPlaysThem() async throws {
    let (window, regionID) = try await flexedWindow()
    #expect(window.flexRenders.count == 1)
    let played = try #require(window.playedProject.region(withID: regionID))
    guard case .audio(let audio) = played.content else { Issue.record("Not audio"); return }
    let render = try #require(window.flexRenders.values.first)
    #expect(audio.fileID == render.id, "Playback uses the render")
    #expect(window.document.url(for: render) != nil, "Playback can find it")
  }

  @Test func bouncesPlayTheFlexedAudio() async throws {
    let (window, _) = try await flexedWindow(mode: .rhythmic)
    let project = window.projectWithCurrentPluginStates()
    let output = folder.appending(path: "Bounce.caf")
    let bouncer = ProjectBouncer(project: project) { [weak document = window.document] in document?.url(for: $0) }
    _ = try await bouncer.bounce(
      try #require(project.bounceRange), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false), to: output)
    let moved = try #require(try onset(in: output, after: 1))
    #expect(abs(moved - 1.75) < 0.03, "The flexed hit is heard at \(moved) s")
  }

  @Test func bouncesWaitForFlexRendersStillBeingMade() async throws {
    let (window, regionID) = try await flexedWindow(mode: .rhythmic, waitingForRenders: false)
    defer { window.engine.shutDown() }
    #expect(window.flexProcessingRegionIDs == [regionID], "The region shows it's processing")
    window.showBounce()
    let bounce = try #require(window.bounce)
    bounce.settings = BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false)
    window.startBounce()
    var result: BounceResult?
    for _ in 0..<400 where result == nil {
      if case .finished(let finished) = bounce.phase { result = finished }
      try await Task.sleep(for: .milliseconds(25))
    }
    let url = try #require(result?.url, "The bounce finished")
    let moved = try #require(try onset(in: url, after: 1))
    #expect(abs(moved - 1.75) < 0.03, "The flexed hit is heard at \(moved) s, not where it was recorded")
    #expect(window.flexProcessingRegionIDs.isEmpty)
    bounce.settings = BounceSettings()
    window.closeBounce()
  }
}
