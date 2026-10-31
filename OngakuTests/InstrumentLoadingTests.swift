//
//  InstrumentLoadingTests.swift
//  OngakuTests
//

import AVFAudio
import AudioToolbox
import Foundation
import OngakuCore
@testable import OngakuEngine
import Synchronization
import Testing

@MainActor
struct InstrumentLoadingTests {
  /// Apple's AUMIDISynth, loaded the same way as a third-party instrument (out of process).
  private let midiSynth = PluginReference(
    componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_MIDISynth,
    componentManufacturer: kAudioUnitManufacturer_Apple, name: "AUMIDISynth")

  private func waitForInstrument(_ engine: PlaybackEngine, track trackID: Track.ID) async throws {
    for _ in 0..<100 where engine.isLoadingInstrument(forTrack: trackID) {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  @Test func generalMIDIInstrumentsLoadImmediately() {
    let track = Track(name: "Inst 1", kind: .softwareInstrument)
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }

    #expect(!engine.isLoadingInstrument(forTrack: track.id))
    #expect(engine.withInstrumentAudioUnit(forTrack: track.id) { $0.audioUnitName } != nil)
    #expect(engine.lastError == nil)
  }

  @Test func audioUnitInstrumentsLoadOutOfProcess() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }

    try await waitForInstrument(engine, track: track.id)
    #expect(engine.lastError == nil)
    let componentSubType = engine.withInstrumentAudioUnit(forTrack: track.id) { $0.componentDescription.componentSubType }
    #expect(componentSubType == kAudioUnitSubType_MIDISynth)
  }

  @Test func switchingInstrumentsReplacesTheAudioUnit() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    var project = Project(tracks: [track])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)

    project.tracks[0].channel.instrument = .generalMIDI(program: 40)
    engine.update(project: project)
    let componentSubType = engine.withInstrumentAudioUnit(forTrack: track.id) { $0.componentDescription.componentSubType }
    #expect(componentSubType == kAudioUnitSubType_Sampler)
  }

  @Test func savedPluginSettingsDontReloadThePlugin() async throws {
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(midiSynth)
    var project = Project(tracks: [track])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await waitForInstrument(engine, track: track.id)

    var plugin = midiSynth
    plugin.state = engine.instrumentState(forTrack: track.id)
    #expect(plugin.state != nil)
    project.tracks[0].channel.instrument = .audioUnit(plugin)
    engine.update(project: project)
    #expect(!engine.isLoadingInstrument(forTrack: track.id))
  }

  /// Adding a track restarts the engine, which used to drop the other samplers back to
  /// their default tone: a piano went dull and bass-like.
  @Test func addingATrackKeepsTheOtherTracksSounds() async throws {
    var piano = Track(name: "Inst 1", kind: .softwareInstrument)
    piano.channel.instrument = .generalMIDI(program: 0)
    var project = Project(tracks: [piano])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(300))
    let before = try await brightness(of: engine, playingOn: piano.id)

    project.tracks.append(Track(name: "Inst 2", kind: .softwareInstrument))
    engine.update(project: project)
    try await Task.sleep(for: .milliseconds(300))
    let after = try await brightness(of: engine, playingOn: piano.id)

    #expect(before > 0)
    #expect(abs(after - before) / before < 0.1, "Inst 1 should still sound like a piano (\(before) → \(after) zero crossings/s)")
    #expect(engine.lastError == nil)
  }

  private final class Recording: @unchecked Sendable {
    let samples = Mutex<[Float]>([])
  }

  /// Plays middle C on a track and counts how often its instrument's output crosses zero per
  /// second: a simple measure of how bright the sound is.
  private func brightness(of engine: PlaybackEngine, playingOn trackID: Track.ID) async throws -> Double {
    let unit = try #require(engine.instruments[trackID]?.instrument)
    let format = unit.outputFormat(forBus: 0)
    let recording = Recording()
    try unit.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      guard case .float(let samples) = buffer.channelData(0) else { return }
      samples.withUnsafeBufferPointer { frames in
        recording.samples.withLock { $0 += frames }
      }
    }
    defer { unit.removeTap(onBus: 0) }
    try await Task.sleep(for: .milliseconds(200))
    recording.samples.withLock { $0 = [] }
    engine.playLive([0x90, 60, 110], onTrack: trackID)
    try await Task.sleep(for: .milliseconds(600))
    engine.playLive([0x80, 60, 0], onTrack: trackID)

    let samples = recording.samples.withLock { $0 }
    // Skip the attack and measure the sustained part of the note.
    let onset = try #require(samples.firstIndex { abs($0) > 0.01 }, "The note should sound")
    let window = samples.dropFirst(onset + 2_000).prefix(8_192)
    try #require(window.count == 8_192, "The note should last long enough to measure")
    let crossings = zip(window, window.dropFirst()).count { ($0 < 0) != ($1 < 0) }
    return Double(crossings) * format.sampleRate / Double(window.count)
  }
}
