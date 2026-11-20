//
//  SmartControlTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Smart Controls and controller assignments (MIDI Learn).
struct SmartControlTests {
  private func project() -> (Project, Track, PluginParameter) {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let synth = PluginReference(componentType: 0x6175_6D75, componentSubType: 1, componentManufacturer: 2, name: "Synth")
    keys.channel.instrument = .audioUnit(synth)
    let verb = Track(name: "Verb", kind: .aux)
    keys.channel.sends = [Send(destinationTrackID: verb.id)]
    return (Project(tracks: [keys, verb]), keys, PluginParameter(pluginID: synth.id, address: 7, name: "Cutoff"))
  }

  @Test func knobsAreMappedToTheTracksControls() throws {
    var (project, keys, cutoff) = project()
    try SetSmartControls([.plugin(cutoff), .volume], on: keys.id).apply(to: &project)
    let first = project.tracks[0].smartControls
    #expect(first.map(\.parameter) == [.plugin(cutoff), .volume])
    try SetSmartControls([.volume, .plugin(cutoff), .pan], on: keys.id).apply(to: &project)
    #expect(project.tracks[0].smartControls.map(\.id).prefix(2) == [first[1].id, first[0].id], "Knobs that stay keep their identity")

    let other = PluginParameter(pluginID: UUID(), address: 1, name: "Elsewhere")
    #expect(throws: EditError.self) { try SetSmartControls([.plugin(other)], on: keys.id).apply(to: &project) }
    #expect(throws: EditError.self) { try SetSmartControls(Array(repeating: .volume, count: 9), on: keys.id).apply(to: &project) }
  }

  @Test func aControllerPlaysOneControlAndAControlHasOneController() throws {
    var (project, keys, cutoff) = project()
    try AssignController(ControllerAssignment(channel: 0, controller: 74, trackID: keys.id, parameter: .plugin(cutoff))).apply(to: &project)
    try AssignController(ControllerAssignment(channel: 0, controller: 74, trackID: keys.id, parameter: .volume)).apply(to: &project)
    #expect(project.controllerAssignments.map(\.parameter) == [.volume], "Learning a controller again moves it")
    try AssignController(ControllerAssignment(channel: 1, controller: 7, trackID: keys.id, parameter: .volume)).apply(to: &project)
    #expect(project.controllerAssignments.map(\.controller) == [7], "A control learns a new controller in place of its old one")
    #expect(project.controllerAssignment(for: .volume, on: keys.id)?.description == "CC 7, channel 2")
    #expect(throws: EditError.self) {
      try AssignController(ControllerAssignment(channel: 16, controller: 1, trackID: keys.id, parameter: .pan)).apply(to: &project)
    }
  }

  @MainActor @Test func controlsThatGoTakeTheirKnobsAndControllersWithThem() throws {
    let (project, keys, cutoff) = project()
    let editor = ProjectEditor(project: project)
    try editor.perform(CompositeCommand("Set Up", commands: [
      SetSmartControls([.plugin(cutoff), .sendLevel(keys.channel.sends[0].id), .pan], on: keys.id),
      AssignController(ControllerAssignment(channel: 0, controller: 74, trackID: keys.id, parameter: .plugin(cutoff))),
    ]), undoManager: nil)
    var channel = editor.project.tracks[0].channel
    channel.instrument = .generalMIDI(program: 0)
    try editor.perform(SetChannelStrip(keys.id, to: channel), undoManager: nil)
    try editor.perform(RemoveSend(keys.channel.sends[0].id, from: keys.id), undoManager: nil)
    #expect(editor.project.tracks[0].smartControls.map(\.parameter) == [.pan])
    #expect(editor.project.controllerAssignments.isEmpty)
  }

  @Test func smartControlsAndAssignmentsAreSavedAndDuplicated() throws {
    var (project, keys, cutoff) = project()
    project.tracks[0].automation = [AutomationLane(parameter: .plugin(cutoff), points: [AutomationPoint(position: .zero, value: 0.2)])]
    try SetSmartControls([.plugin(cutoff), .volume], on: keys.id).apply(to: &project)
    try AssignController(ControllerAssignment(channel: 0, controller: 1, trackID: keys.id, parameter: .volume)).apply(to: &project)
    let decoded = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(decoded.tracks[0].smartControls == project.tracks[0].smartControls)
    #expect(decoded.controllerAssignments == project.controllerAssignments)

    let copyID = UUID()
    try DuplicateTrack(keys.id, copyID: copyID).apply(to: &project)
    let copy = try #require(project.track(withID: copyID))
    guard case .audioUnit(let synth) = copy.channel.instrument else { Issue.record(); return }
    #expect(copy.smartControls.map(\.parameter) == [.plugin(PluginParameter(pluginID: synth.id, address: 7, name: "Cutoff")), .volume])
    #expect(copy.automation.count == 1, "The copy's instrument keeps its automation too")
  }
}
