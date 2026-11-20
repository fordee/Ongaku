//
//  PluginQuitTests.swift
//  OngakuTests
//

import AudioToolbox
import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// A plug-in's process can quit (it crashed). The system says so; the plug-in is started
/// again, unless it keeps quitting.
@MainActor
@Suite(.serialized)
struct PluginQuitTests {
  init() {
    TestMIDIPlugins.register
  }

  private func quit(_ audioUnit: AUAudioUnit) {
    NotificationCenter.default.post(
      name: Notification.Name(kAudioComponentInstanceInvalidationNotification as String), object: audioUnit)
  }

  /// Waits up to five seconds for `condition`.
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<250 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  @Test func plugInsThatQuitAreStartedAgainUntilTheyKeepQuitting() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .audioUnit(PluginReference(description: TestMIDIPlugins.recorder, name: "Recorder"))
    let octaveUp = MIDIEffect(.audioUnit(PluginReference(description: TestMIDIPlugins.transposer, name: "Octave Up")))
    keys.channel.midiEffects = [octaveUp]
    let delay = BuiltInEffect.delay.makeReference()
    keys.channel.inserts = [delay]
    let engine = PlaybackEngine(project: Project(tracks: [keys])) { _ in nil }
    defer { engine.shutDown() }
    let effectID = try #require(octaveUp.plugin?.id)

    func instrument() -> AUAudioUnit? { engine.withInstrumentAudioUnit(forTrack: keys.id) { copy $0 } }
    func midiEffect() -> AUAudioUnit? { engine.withMIDIEffectAudioUnit(effectID, onTrack: keys.id) { copy $0 } }
    func insert() -> AUAudioUnit? { engine.withInsertAudioUnit(delay.id, onTrack: keys.id) { copy $0 } }
    #expect(try await eventually { instrument() != nil && midiEffect() != nil && insert() != nil }, "Everything loads")

    // Each kind is started again.
    for (name, current) in [("Recorder", instrument), ("Octave Up", midiEffect), ("Apple Delay", insert)] as [(String, () -> AUAudioUnit?)] {
      let before = try #require(current())
      quit(before)
      #expect(try await eventually { current().map { $0 !== before } == true }, "\(name) is started again")
      #expect(engine.lastError?.contains("quit unexpectedly and was started again") == true, "\(String(describing: engine.lastError))")
    }

    // The instrument quits twice more: it stays off.
    for _ in 0..<2 {
      let before = try #require(try await eventually { instrument() != nil } ? instrument() : nil)
      quit(before)
      #expect(try await eventually { instrument() !== before })
    }
    #expect(engine.lastError?.contains("keeps quitting") == true, "\(String(describing: engine.lastError))")
    try await Task.sleep(for: .milliseconds(300))
    #expect(instrument() == nil, "Not started again")
    #expect(midiEffect() != nil && insert() != nil, "The others carry on")
  }
}
