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
}
