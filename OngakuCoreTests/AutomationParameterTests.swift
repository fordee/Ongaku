//
//  AutomationParameterTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Send and plug-in parameters as automation lanes.
@MainActor
struct AutomationParameterTests {
  @Test func volumeAndPanAreSavedAsBefore() throws {
    let data = try JSONEncoder().encode([AutomationParameter.volume, .pan])
    #expect(String(decoding: data, as: UTF8.self) == #"["volume","pan"]"#)
  }

  @Test func sendAndPluginParametersRoundTrip() throws {
    let send = AutomationParameter.sendLevel(UUID())
    let plugin = AutomationParameter.plugin(PluginParameter(pluginID: UUID(), address: 7, name: "Mix", initialValue: 0.3))
    let decoded = try JSONDecoder().decode([AutomationParameter].self, from: JSONEncoder().encode([send, plugin]))
    #expect(decoded == [send, plugin])
    if case .plugin(let parameter) = decoded[1] {
      #expect(parameter.name == "Mix")
      #expect(parameter.initialValue == 0.3)
    }
  }

  @Test func pluginParametersAreTheSameParameterWhateverTheirName() {
    let id = UUID()
    #expect(PluginParameter(pluginID: id, address: 3, name: "A") == PluginParameter(pluginID: id, address: 3, name: "B"))
    #expect(PluginParameter(pluginID: id, address: 3, name: "A") != PluginParameter(pluginID: id, address: 4, name: "A"))
  }

  @Test func sendLevelsAreDecibelsWithoutAutomation() {
    let send = Send(destinationTrackID: UUID(), level: -12)
    let channel = ChannelStrip(sends: [send])
    #expect(AutomationParameter.sendLevel(send.id).value(in: channel) == -12)
    #expect(AutomationParameter.sendLevel(send.id).isDecibels)
    #expect(AutomationParameter.sendLevel(send.id).range == Send.levelRange)
  }

  @Test func automatedSendsAreListed() {
    let send = Send(destinationTrackID: UUID())
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.channel.sends = [send]
    track.automation = [AutomationLane(parameter: .sendLevel(send.id), points: [AutomationPoint(position: .zero, value: -3)])]
    #expect(track.automatedSends == [send.id])
    #expect(track.automatedParameters == [.volume, .pan, .sendLevel(send.id)])
  }

  @Test func removingASendOrInsertRemovesItsAutomation() throws {
    let aux = Track(name: "Aux", kind: .aux)
    let send = Send(destinationTrackID: aux.id)
    let insert = BuiltInEffect.delay.makeReference()
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.channel.sends = [send]
    track.channel.inserts = [insert]
    let point = [AutomationPoint(position: .zero, value: 0)]
    track.automation = [
      AutomationLane(parameter: .sendLevel(send.id), points: point),
      AutomationLane(parameter: .plugin(PluginParameter(pluginID: insert.id, address: 1, name: "Mix")), points: point),
      AutomationLane(parameter: .volume, points: point),
    ]
    let editor = ProjectEditor(project: Project(tracks: [track, aux]))
    var channel = track.channel
    channel.sends = []
    channel.inserts = []
    try editor.perform(SetChannelStrip(track.id, to: channel), undoManager: nil)
    #expect(editor.project.tracks[0].automation.map(\.parameter) == [.volume])
  }

  @Test func instrumentAndMIDIEffectPluginsCanBeAutomated() throws {
    let synth = OngakuInstrument.retroSynth.makeReference()
    // A MIDI processor ('aumi'), as a third-party arpeggiator would be.
    let arpeggiator = PluginReference(componentType: 0x6175_6D69, componentSubType: 0x6172_7070, componentManufacturer: 0x5465_7374, name: "Arp")
    var track = Track(name: "Synth", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(synth)
    track.channel.midiEffects = [MIDIEffect(.audioUnit(arpeggiator))]
    #expect(track.channel.plugins.map(\.id) == [arpeggiator.id, synth.id], "MIDI effects, then the instrument")
    let point = [AutomationPoint(position: .zero, value: 0)]
    track.automation = [
      AutomationLane(parameter: .plugin(PluginParameter(pluginID: synth.id, address: 428, name: "Volume")), points: point),
      AutomationLane(parameter: .plugin(PluginParameter(pluginID: arpeggiator.id, address: 1, name: "Rate")), points: point),
    ]
    let editor = ProjectEditor(project: Project(tracks: [track]))
    try editor.perform(SetTrackColor(track.id, to: .blue), undoManager: nil)
    #expect(editor.project.tracks[0].automation.count == 2, "Kept while the plug-ins are on the strip")

    var channel = track.channel
    channel.instrument = .generalMIDI(program: 0)
    channel.midiEffects = []
    try editor.perform(SetChannelStrip(track.id, to: channel), undoManager: nil)
    #expect(editor.project.tracks[0].automation.isEmpty, "Replacing them takes their automation")
  }
}
