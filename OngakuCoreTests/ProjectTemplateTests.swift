//
//  ProjectTemplateTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Templates: a song's setup without its music, and new songs made from one.
struct ProjectTemplateTests {
  private func song() -> Project {
    let verb = Track(name: "Verb", kind: .aux)
    let bus = Track(name: "Drums", kind: .aux)
    var kick = Track(name: "Kick", kind: .audio)
    kick.regions = [Region(name: "Kick", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: UUID())))]
    kick.channel.output = .track(bus.id)
    kick.automation = [AutomationLane(parameter: .volume, points: [AutomationPoint(position: .zero, value: -3)])]
    var bass = Track(name: "Bass", kind: .softwareInstrument)
    let compressor = PluginReference(componentType: 0x6175_6678, componentSubType: 1, componentManufacturer: 2, name: "Comp")
    var keyed = compressor
    keyed.sidechainSourceID = kick.id
    bass.channel.inserts = [keyed]
    bass.channel.sends = [Send(destinationTrackID: verb.id, level: -8)]
    bass.smartControls = [SmartControl(parameter: .plugin(PluginParameter(pluginID: keyed.id, address: 3, name: "Ratio"))), SmartControl(parameter: .sendLevel(bass.channel.sends[0].id))]
    bass.isRecordArmed = true
    var project = Project(tempoMap: TempoMap(bpm: 96), tracks: [kick, bus, bass, verb])
    project.markers = [Marker(name: "Verse", position: .zero)]
    project.controllerAssignments = [ControllerAssignment(channel: 0, controller: 21, trackID: bass.id, parameter: .sendLevel(bass.channel.sends[0].id))]
    return project
  }

  @Test func aTemplateKeepsTheSetupButNotTheMusic() {
    let template = song().template()
    #expect(template.tracks.map(\.name) == ["Kick", "Drums", "Bass", "Verb"])
    #expect(template.tracks.allSatisfy { $0.regions.isEmpty && $0.automation.isEmpty && !$0.isRecordArmed })
    #expect(template.markers.isEmpty && template.audioFiles.isEmpty)
    #expect(template.tempoMap.tempo(at: .zero) == 96)
    #expect(template.tracks[2].channel.inserts.count == 1 && template.tracks[2].smartControls.count == 2)
    #expect(template.controllerAssignments.count == 1)
  }

  @Test func eachNewSongGetsItsOwnTracksPlugInsAndSends() throws {
    let template = song().template()
    let new = template.fromTemplate()
    #expect(Set(new.tracks.map(\.id)).isDisjoint(with: template.tracks.map(\.id)))
    let (kick, bus, bass, verb) = (new.tracks[0], new.tracks[1], new.tracks[2], new.tracks[3])
    #expect(kick.channel.output == .track(bus.id), "Outputs follow the new tracks")
    #expect(bass.channel.sends[0].destinationTrackID == verb.id)
    let compressor = try #require(bass.channel.inserts.first)
    #expect(compressor.id != template.tracks[2].channel.inserts[0].id)
    #expect(compressor.sidechainSourceID == kick.id)
    #expect(bass.smartControls.map(\.parameter) == [
      .plugin(PluginParameter(pluginID: compressor.id, address: 3, name: "Ratio")), .sendLevel(bass.channel.sends[0].id),
    ])
    #expect(new.controllerAssignments.first?.trackID == bass.id)
    #expect(new.controllerAssignments.first?.parameter == .sendLevel(bass.channel.sends[0].id))
    // Everything still makes sense to the editor's checks.
    var checked = new
    checked.removeOrphanedControls()
    #expect(checked == new)
  }
}
