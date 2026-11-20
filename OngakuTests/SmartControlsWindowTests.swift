//
//  SmartControlsWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The Smart Controls panel and MIDI Learn, driven as the panel and a MIDI controller drive them.
@MainActor
@Suite(.serialized)
struct SmartControlsWindowTests {
  private func makeWindow() -> ProjectWindowModel {
    let verb = Track(name: "Verb", kind: .aux)
    var vocal = Track(name: "Vocal", kind: .audio)
    vocal.channel.sends = [Send(destinationTrackID: verb.id)]
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [vocal, verb])))
    window.selectedTrackID = vocal.id
    return window
  }

  @Test func aTrackWithoutPlugInsSuggestsItsChannelStrip() throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let vocal = window.project.tracks[0]
    #expect(window.smartControls(for: vocal) == [.volume, .pan, .sendLevel(vocal.channel.sends[0].id)])
    #expect(window.controlName(.sendLevel(vocal.channel.sends[0].id), on: vocal) == "Send to Verb")

    // Mapping one knob keeps the suggestions on the others.
    window.mapSmartControl(1, on: vocal, to: .volume)
    #expect(window.project.tracks[0].smartControls.map(\.parameter) == [.pan, .volume, .sendLevel(vocal.channel.sends[0].id)])
    window.mapSmartControl(0, on: window.project.tracks[0], to: nil)
    #expect(window.project.tracks[0].smartControls.map(\.parameter) == [.volume, .sendLevel(vocal.channel.sends[0].id)])
  }

  @Test func midiLearnAssignsTheNextControllerAndItMovesTheControl() async throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let vocal = window.project.tracks[0]
    window.beginMIDILearn(SmartControlTarget(trackID: vocal.id, parameter: .pan))
    window.controllerMoved(MIDIInputRouter.Controller(channel: 2, number: 10), to: 64)
    #expect(window.midiLearnTarget == nil)
    #expect(window.project.controllerAssignment(for: .pan, on: vocal.id)?.controller == 10)
    #expect(window.project.tracks[0].channel.pan == 0, "Learning doesn't move the control")

    // Hard left: once the controller stops, the pan is stored.
    window.controllerMoved(MIDIInputRouter.Controller(channel: 2, number: 10), to: 0)
    try await Task.sleep(for: .milliseconds(700))
    #expect(window.project.tracks[0].channel.pan == -1)
    // Other channels' controller 10 isn't it.
    window.controllerMoved(MIDIInputRouter.Controller(channel: 0, number: 10), to: 127)
    try await Task.sleep(for: .milliseconds(700))
    #expect(window.project.tracks[0].channel.pan == -1)
  }

  @Test func controllersCoverEachControlsRange() {
    #expect(ProjectWindowModel.controlValue(ofController: 127, for: .pan) == 1)
    #expect(ProjectWindowModel.controlValue(ofController: 0, for: .volume) == ChannelStrip.volumeRange.lowerBound)
    #expect(ProjectWindowModel.controlValue(ofController: 127, for: .volume) == FaderScale.maximum)
    let cutoff = PluginParameter(pluginID: UUID(), address: 1, name: "Cutoff")
    #expect(abs(ProjectWindowModel.controlValue(ofController: 64, for: .plugin(cutoff)) - 64.0 / 127) < 1e-9)
  }
}
