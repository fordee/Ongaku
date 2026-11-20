//
//  InstrumentOutputLiveTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// A multi-output instrument's other outputs, playing live through their aux tracks.
@MainActor
@Suite(.serialized)
struct InstrumentOutputLiveTests {
  init() {
    TestMIDIPlugins.register
  }

  @Test func extraOutputsAreNamedAndHeardOnTheirAuxTracks() async throws {
    var kit = Track(name: "Kit", kind: .softwareInstrument)
    kit.channel.instrument = .audioUnit(PluginReference(description: TestMIDIPlugins.twoOutputInstrument, name: "Two Outputs"))
    var project = Project(tracks: [kit])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    for _ in 0..<100 where engine.extraInstrumentOutputNames(forTrack: kit.id).isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    let names = engine.extraInstrumentOutputNames(forTrack: kit.id)
    #expect(names == ["Rim"], "Named as the instrument names it")

    try AddInstrumentOutputs(of: kit.id, outputNames: names).apply(to: &project)
    let rim = project.tracks[1].id
    engine.update(project: project)
    var peak: Float = -60
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(25))
      peak = max(peak, engine.meters.level(for: rim).peakDecibels)
    }
    #expect(peak > -10, "The rim output is heard on its aux (\(peak) dB)")
    #expect(engine.meters.level(for: kit.id).peakDecibels <= -59, "Not on the instrument's own track")
  }
}
