//
//  MIDIEffectPluginTests.swift
//  OngakuTests
//

import AudioToolbox
import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Third-party MIDI effects (Audio Unit MIDI processors) in MIDI FX slots.
@Suite(.serialized)
struct MIDIEffectPluginTests {
  init() {
    TestMIDIPlugins.register
    TestMIDIPlugins.clearRecordedNotes()
  }

  /// An instrument track's MIDI goes into its first MIDI effect plug-in, and on to the
  /// instrument; bypassing or removing the plug-in sends it straight to the instrument again.
  @MainActor
  @Test func instrumentsPlayThroughTheirMIDIEffectPlugins() async throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
    let channel = InstrumentChannel(engine: engine, destination: engine.mainMixerNode)
    try await channel.load(.audioUnit(PluginReference(description: TestMIDIPlugins.recorder, name: "Recorder")), format: format)
    let octaveUp = PluginReference(description: TestMIDIPlugins.transposer, name: "Octave Up")
    func set(_ effects: [PluginReference]) -> Bool {
      channel.setMIDIEffects(effects, format: format, maximumFrames: 512, onLoadFailure: { _, error in Issue.record(error) }, onInstalled: {})
    }
    _ = set([octaveUp])
    await channel.waitForPendingMIDIEffects()
    #expect(channel.playingMIDIEffectCount == 1, "MIDI goes through the plug-in")
    try engine.start()
    defer {
      channel.detach()
      engine.stop()
    }
    _ = try engine.renderOffline(512, to: buffer)

    func played(_ play: () -> Void) throws -> [Int] {
      TestMIDIPlugins.clearRecordedNotes()
      play()
      for _ in 0..<4 { _ = try engine.renderOffline(512, to: buffer) }
      return TestMIDIPlugins.recordedNoteOns.map(\.pitch)
    }

    #expect(try played { channel.playNow([0x90, 60, 100]) } == [72], "Played live")
    // Queued a little after the instrument's last render: the plug-in plays in its timeline.
    let rendered = try #require(channel.lastRenderSampleTime)
    #expect(try played { channel.queue.push(sampleTime: rendered + 1_000, bytes: [0x90, 62, 100]) } == [74], "Scheduled")
    #expect(TestMIDIPlugins.recordedNoteOns.first?.sampleTime == rendered + 1_000, "On the sample it was scheduled for")

    var bypassed = octaveUp
    bypassed.isBypassed = true
    #expect(set([bypassed]), "The chain changed")
    #expect(channel.playingMIDIEffectCount == 0)
    #expect(try played { channel.playNow([0x90, 64, 100]) } == [64], "Bypassed")
    let rendersBefore = TestMIDIPlugins.transposerRenders.count

    #expect(set([octaveUp]))
    #expect(try played { channel.playNow([0x90, 65, 100]) } == [77], "On again, without reloading")
    for _ in 0..<100 { _ = try engine.renderOffline(512, to: buffer) }
    #expect(TestMIDIPlugins.transposerRenders.count - rendersBefore == 104, "It renders every cycle while it plays")

    #expect(set([]))
    #expect(channel.playingMIDIEffectCount == 0)
    #expect(try played { channel.playNow([0x90, 67, 100]) } == [67], "Removed")
  }

  /// Plug-ins stay after Ongaku's own effects, which change notes before they play; their
  /// settings are saved like any plug-in's.
  @Test func plugInsComeAfterOngakusOwnMIDIEffectsAndKeepTheirSettings() throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let plugin = MIDIEffect(.audioUnit(PluginReference(description: TestMIDIPlugins.transposer, name: "Octave Up")))
    let transposer = MIDIEffect(.transposer(Transposer(semitones: 2)))
    keys.channel.midiEffects = [plugin]
    var project = Project(tracks: [keys])

    try AddMIDIEffect(transposer, to: keys.id).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects.map(\.id) == [transposer.id, plugin.id], "Added after the plug-in, played before it")
    try MoveMIDIEffect(transposer.id, in: keys.id, to: 1).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects.map(\.id) == [transposer.id, plugin.id])

    let pluginID = try #require(plugin.plugin?.id)
    try SetPluginState(Data([1, 2, 3]), forPlugin: pluginID, on: keys.id).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects[1].plugin?.state == Data([1, 2, 3]))

    // Played notes only go through Ongaku's own effects; the plug-in plays them later.
    let notes = [EffectNote(start: .zero, end: Tick(rawValue: 480), pitch: 60, velocity: 100)]
    #expect(project.tracks[0].channel.midiEffects.process(notes).map(\.pitch) == [62])
  }

  /// Playing the song live: the region's notes reach the instrument through the plug-in, a
  /// beat apart as written.
  @MainActor
  @Test func theSongPlaysThroughMIDIEffectPluginsInTime() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .audioUnit(PluginReference(description: TestMIDIPlugins.recorder, name: "Recorder"))
    let octaveUp = MIDIEffect(.audioUnit(PluginReference(description: TestMIDIPlugins.transposer, name: "Octave Up")))
    keys.channel.midiEffects = [octaveUp]
    let notes = [
      MIDINote(pitch: 60, velocity: 100, start: .zero, length: .quarterNotes(0.5)),
      MIDINote(pitch: 62, velocity: 100, start: .quarterNotes(1), length: .quarterNotes(0.5)),
    ]
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: notes)))]
    let engine = PlaybackEngine(project: Project(tracks: [keys])) { _ in nil }
    defer { engine.shutDown() }
    let pluginID = try #require(octaveUp.plugin?.id)
    for _ in 0..<100 where engine.isLoadingInstrument(forTrack: keys.id) || engine.isLoadingMIDIEffect(pluginID, onTrack: keys.id) {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(200))

    engine.play()
    try await Task.sleep(for: .milliseconds(1_000))
    engine.stop()
    let played = TestMIDIPlugins.recordedNoteOns
    #expect(played.map(\.pitch) == [72, 74], "Both notes, an octave up")
    #expect(engine.lastError == nil)
    if played.count == 2 {
      // A beat at 120 BPM is half a second.
      let gap = Double(played[1].sampleTime - played[0].sampleTime) / engine.outputSampleRate
      #expect(abs(gap - 0.5) < 0.001, "A beat apart: \(gap) s")
    }
  }
}
