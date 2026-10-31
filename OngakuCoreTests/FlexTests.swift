//
//  FlexTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Flex Time: the time map, rendering in both modes, finding transients and quantizing.
struct FlexTests {
  private let rate = 48_000.0

  /// Clicks (a 2 ms burst of a 2 kHz tone) at the given times, in `duration` seconds of silence.
  private func clicks(at times: [Double], duration: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(duration * rate))
    for time in times {
      let start = Int(time * rate)
      for index in 0..<96 where start + index < samples.count {
        samples[start + index] = 0.8 * sin(2 * .pi * 2_000 * Float(index) / Float(rate))
      }
    }
    return samples
  }

  /// The first sample above a threshold after `from` seconds, in seconds.
  private func onset(in samples: [Float], after from: Double = 0) -> Double? {
    let start = Int(from * rate)
    guard let index = samples.indices.dropFirst(start).first(where: { abs(samples[$0]) > 0.2 }) else { return nil }
    return Double(index) / rate
  }

  // MARK: - Time map

  @Test func theMapRunsThroughEachMarker() {
    // The moment 1 s in plays at 1.5 s; the region stays 4 s long.
    let map = FlexMap(markers: [FlexMarker(source: 1, target: 1.5)], duration: 4)
    #expect(map.sourceTime(atTarget: 1.5) == 1)
    #expect(map.sourceTime(atTarget: 0.75) == 0.5, "Stretched before the marker")
    #expect(abs(map.sourceTime(atTarget: 2.75) - 2.5) < 1e-9, "Squeezed after it")
    #expect(map.targetTime(atSource: 1) == 1.5)
    #expect(map.sourceTime(atTarget: 4) == 4)
  }

  @Test func markersMustStayInOrder() {
    #expect(FlexMap.isValid([FlexMarker(source: 1, target: 1.2), FlexMarker(source: 2, target: 2.5)], duration: 4))
    #expect(!FlexMap.isValid([FlexMarker(source: 1, target: 2.6), FlexMarker(source: 2, target: 2.5)], duration: 4), "Crossing")
    #expect(!FlexMap.isValid([FlexMarker(source: 1, target: 4.2)], duration: 4), "Past the end")
  }

  // MARK: - Rendering

  @Test func slicingMovesHitsExactly() {
    let source = clicks(at: [0.5, 1.5], duration: 3)
    // The second click moves 0.25 s later.
    let map = FlexMap(markers: [FlexMarker(source: 1.5, target: 1.75)], duration: 3)
    let output = FlexRenderer.render([source], map: map, mode: .slicing, sampleRate: rate)[0]
    #expect(output.count == source.count)
    #expect(onset(in: output).map { abs($0 - 0.5) < 0.0005 } == true)
    let moved = onset(in: output, after: 1)
    #expect(moved.map { abs($0 - 1.75) < 0.0005 } == true, "The moved hit lands on time (\(String(describing: moved)))")
  }

  @Test func stretchingKeepsLengthAndMovesHits() {
    let source = clicks(at: [0.5, 1.5, 2.5], duration: 3)
    let map = FlexMap(markers: [FlexMarker(source: 1.5, target: 1.75)], duration: 3)
    let output = FlexRenderer.render([source, source], map: map, mode: .rhythmic, sampleRate: rate)
    #expect(output.count == 2)
    #expect(output[0].count == source.count)
    // Time-stretching smears a click a little: each lands within a window of its place.
    let tolerance = 0.03
    // Each click lands where the map puts it: stretched before the marker, squeezed after.
    for (source, after) in [(0.5, 0.2), (1.5, 1.2), (2.5, 2.2)] {
      let expected = map.targetTime(atSource: source)
      let found = onset(in: output[0], after: after)
      #expect(found.map { abs($0 - expected) < tolerance } == true, "Expected a hit near \(expected) s, found \(String(describing: found))")
    }
  }

  @Test func stretchingKeepsPitch() {
    // A 440 Hz tone stretched by 25 % still has 440 zero-crossing pairs per second.
    let tone = (0..<Int(2 * rate)).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
    let map = FlexMap(markers: [FlexMarker(source: 0.8, target: 1)], duration: 2)
    let output = FlexRenderer.render([tone], map: map, mode: .rhythmic, sampleRate: rate)[0]
    let middle = output[Int(0.3 * rate)..<Int(0.7 * rate)]
    let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    #expect(abs(Double(crossings) / 0.4 - 440) < 10, "\(Double(crossings) / 0.4) Hz")
  }

  // MARK: - Transients and quantize

  @Test func transientsAreFound() {
    let times = [0.25, 0.75, 1.0, 1.6]
    let found = TransientDetector.detect(clicks(at: times, duration: 2), sampleRate: rate)
    #expect(found.count == times.count)
    for (detected, expected) in zip(found, times) {
      #expect(abs(detected - expected) < 0.01, "\(detected) vs \(expected)")
    }
  }

  @Test func quantizingMovesTransientsToTheGrid() {
    // A one-bar region at 120 BPM (2 s); eighth notes are 0.25 s apart.
    let file = AudioFileReference(fileName: "Drums.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let region = Region(name: "Drums", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    let project = Project(tracks: [Track(name: "Drums", kind: .audio, regions: [region])], audioFiles: [file])
    let markers = project.quantizedFlexMarkers(for: region, transients: [0.27, 0.71, 1.24], grid: Tick(480))
    #expect(markers.map(\.target) == [0.25, 0.75, 1.25])
    let half = project.quantizedFlexMarkers(for: region, transients: [0.27], grid: Tick(480), strength: 0.5)
    #expect(abs(half[0].target - 0.26) < 1e-9)
  }

  @Test func flexedRegionsPlayTheirRender() throws {
    let file = AudioFileReference(fileName: "Drums.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let render = AudioFileReference(fileName: "Render.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let marker = FlexMarker(source: 0.5, target: 0.6)
    let region = Region(
      name: "Drums", start: .zero, length: .quarterNotes(4),
      content: .audio(AudioRegionContent(fileID: file.id, gain: -3, flexMarkers: [marker])))
    var track = Track(name: "Drums", kind: .audio, regions: [region])
    var project = Project(tracks: [track], audioFiles: [file])
    #expect(project.flexRenderKey(for: region, on: track) == nil, "Flex is off")

    track.flexMode = .slicing
    project.tracks[0] = track
    let key = try #require(project.flexRenderKey(for: region, on: track))
    #expect(key.frameCount == 96_000)
    let played = project.playingFlexRenders([key: render])
    #expect(played.tracks[0].regions[0].content == .audio(AudioRegionContent(fileID: render.id, gain: -3)))
    #expect(played.audioFile(withID: render.id) == render)
  }

  @Test func markersAreEditedThroughTheCommand() throws {
    let file = AudioFileReference(fileName: "Drums.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let region = Region(name: "Drums", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(tracks: [Track(name: "Drums", kind: .audio, regions: [region])], audioFiles: [file])
    try SetFlexMarkers([FlexMarker(source: 1, target: 1.1)], in: region.id).apply(to: &project)
    #expect(throws: EditError.self) {
      try SetFlexMarkers([FlexMarker(source: 1, target: 2.5)], in: region.id).apply(to: &project)
    }
    #expect(throws: EditError.self) { try SplitRegion(region.id, at: .quarterNotes(2)).apply(to: &project) }
    try SetFlexMode(.rhythmic, for: project.tracks[0].id).apply(to: &project)
    #expect(project.tracks[0].flexMode == .rhythmic)
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened == project)
  }
}
