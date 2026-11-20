//
//  VCAAndFolderStackTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Logic's VCA faders and folder stacks: faders that move other tracks' faders.
struct VCAAndFolderStackTests {
  private func project() -> Project {
    var drums = Track(name: "Drums", kind: .audio)
    drums.channel.volume = -6
    drums.automation = [AutomationLane(parameter: .volume, points: [AutomationPoint(position: .zero, value: -10)])]
    var bass = Track(name: "Bass", kind: .audio)
    bass.channel.volume = ChannelStrip.volumeRange.lowerBound
    return Project(tracks: [drums, bass, Track(name: "Keys", kind: .audio)])
  }

  @Test func aVCAMovesItsTracksFadersAndAutomation() throws {
    var project = project()
    let vca = VCA(name: "VCA 1", volume: -3)
    let ids = Set(project.tracks.prefix(2).map(\.id))
    try AddVCA(vca, assigning: ids).apply(to: &project)
    let mixed = project.mixingFoldersAndVCAs()
    #expect(mixed.tracks[0].channel.volume == -9)
    #expect(mixed.tracks[0].automation[0].points[0].value == -13, "Automated volume moves too")
    #expect(mixed.tracks[1].channel.volume == ChannelStrip.volumeRange.lowerBound, "A fader at -∞ stays there")
    #expect(mixed.tracks[2].channel.volume == 0, "Tracks it isn't assigned don't move")
    #expect(project.tracks[0].channel.volume == -6, "The tracks' own faders don't change")

    var muted = vca
    muted.volume = -3
    muted.isMuted = true
    try UpdateVCA(muted).apply(to: &project)
    #expect(project.mixingFoldersAndVCAs().tracks.map(\.channel.isMuted) == [true, true, false])

    try DeleteVCA(vca.id).apply(to: &project)
    #expect(project.vcas.isEmpty && project.tracks.allSatisfy { $0.channel.vcaID == nil })
    #expect(project.mixingFoldersAndVCAs() == project)
  }

  @Test func aFolderStackGathersTracksAndMovesTheirFaders() throws {
    var project = project()
    var output = project
    let aux = Track(name: "Bus", kind: .aux)
    output.tracks.append(aux)
    output.tracks[0].channel.output = .track(aux.id)
    project = output
    let folder = Track(name: "Folder", kind: .aux)
    try CreateFolderStack([project.tracks[0].id, project.tracks[1].id], stack: folder).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Folder", "Drums", "Bass", "Keys", "Bus"])
    #expect(project.tracks[0].isFolderStack && project.tracks[1].stackID == folder.id)
    #expect(project.tracks[1].channel.output == .track(aux.id), "Subtracks keep their outputs")

    project.tracks[0].channel.volume = 4
    project.tracks[0].channel.isSoloed = true
    let mixed = project.mixingFoldersAndVCAs()
    #expect(mixed.tracks[1].channel.volume == -2)
    #expect(mixed.tracks[1].channel.isSoloed && mixed.tracks[2].channel.isSoloed && !mixed.tracks[3].channel.isSoloed)
    #expect(mixed.tracks[0].channel.isMuted && !mixed.tracks[0].channel.isSoloed, "The folder's own strip plays nothing")

    #expect(throws: EditError.self) { try SetTrackOutput(project.tracks[3].id, to: .track(folder.id)).apply(to: &project) }
    try SetTrackOutput(project.tracks[1].id, to: .stereoOut).apply(to: &project)
    #expect(project.tracks[1].stackID == folder.id, "Changing a folder subtrack's output keeps it in the folder")

    try FlattenStack(folder.id).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Drums", "Bass", "Keys", "Bus"])
    #expect(project.tracks.allSatisfy { $0.stackID == nil })
  }

  @Test func foldersAndVCAsAreSaved() throws {
    var project = project()
    try CreateFolderStack([project.tracks[2].id], stack: Track(name: "Folder", kind: .aux)).apply(to: &project)
    try AddVCA(VCA(name: "VCA 1", volume: 2), assigning: [project.tracks[1].id]).apply(to: &project)
    let decoded = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(decoded.vcas == project.vcas)
    #expect(decoded.tracks.map(\.isFolderStack) == project.tracks.map(\.isFolderStack))
    #expect(decoded.tracks.map(\.channel.vcaID) == project.tracks.map(\.channel.vcaID))
  }
}
