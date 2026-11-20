//
//  PluginManagerTests.swift
//  OngakuTests
//

import AudioToolbox
import Foundation
@testable import Ongaku
import OngakuCore
@testable import OngakuEngine
import Testing

/// The Plug-in Manager: checking plug-ins, and which ones the menus offer.
@MainActor
@Suite(.serialized)
struct PluginManagerTests {
  private let suite = "PluginManagerTests-\(UUID().uuidString)"

  init() {
    TestMIDIPlugins.register
  }

  private func entry(_ description: AudioComponentDescription, version: String = "1.0") -> InstrumentLibrary.Entry {
    InstrumentLibrary.Entry(
      manufacturer: "Test", name: "Test Plug-in", componentType: description.componentType,
      componentSubType: description.componentSubType, componentManufacturer: description.componentManufacturer, version: version)
  }

  @Test func workingPlugInsPassTheirCheck() async {
    for description in [TestMIDIPlugins.recorder, TestMIDIPlugins.transposer] {
      let result = await PluginCheck.check(entry(description))
      #expect(result.passed, "\(result)")
    }
  }

  @Test func missingPlugInsFailTheirCheck() async {
    var missing = TestMIDIPlugins.recorder
    missing.componentSubType = 0x6E6F_6E65  // 'none'
    let result = await PluginCheck.check(entry(missing))
    guard case .failed(let message) = result else {
      Issue.record("A plug-in that isn't installed passed")
      return
    }
    #expect(message.hasPrefix("It couldn’t be loaded"))
  }

  @Test func turnedOffAndFailedPlugInsAreLeftOutOfTheMenus() throws {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = PluginManager(defaults: defaults)
    let synth = entry(TestMIDIPlugins.recorder)
    let arpeggiator = entry(TestMIDIPlugins.transposer)
    #expect(manager.offered([synth, arpeggiator]) == [synth, arpeggiator], "Everything is offered until checked")

    manager.setOffered(false, synth)
    #expect(manager.offered([synth, arpeggiator]) == [arpeggiator])
    manager.setOffered(true, synth)

    manager.record(.failed("It doesn’t take MIDI notes."), for: arpeggiator)
    #expect(manager.offered([synth, arpeggiator]) == [synth], "A failed plug-in is left out")
    manager.setOffered(true, arpeggiator)
    #expect(manager.isOffered(arpeggiator), "…unless it's turned on anyway")

    // Remembered, and a new version is checked afresh.
    let reopened = PluginManager(defaults: defaults)
    #expect(reopened.isOffered(arpeggiator))
    reopened.setOffered(false, arpeggiator)
    reopened.record(.failed("Still broken"), for: arpeggiator)
    let updated = entry(TestMIDIPlugins.transposer, version: "2.0")
    #expect(reopened.check(of: updated) == nil, "Not checked yet")
    #expect(!reopened.isOffered(updated), "Still turned off")
    reopened.setOffered(true, updated)
    #expect(reopened.isOffered(updated))
    reopened.record(.passed(seconds: 0.1), for: updated)
    #expect(reopened.check(of: updated)?.passed == true)
  }
}
