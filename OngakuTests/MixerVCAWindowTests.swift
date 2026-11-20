//
//  MixerVCAWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// VCAs, folder stacks and dragging inserts, as the Mixer and Track menu drive them.
@MainActor
@Suite(.serialized)
struct MixerVCAWindowTests {
  private func makeWindow() -> ProjectWindowModel {
    var vocal = Track(name: "Vocal", kind: .audio)
    // Apple's own effects, which load in process. (A made-up all-zero reference would match
    // any plug-in, since zero is a wildcard in an Audio Unit description.)
    vocal.channel.inserts = zip([BuiltInEffect.channelEQ, .compressor, .reverb], ["EQ", "Comp", "Verb"]).map { effect, name in
      var reference = effect.makeReference()
      reference.name = name
      return reference
    }
    return ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      vocal, Track(name: "Gtr", kind: .audio), Track(name: "Keys", kind: .softwareInstrument),
    ])))
  }

  @Test func insertsAreDraggedIntoANewOrder() throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let vocal = window.project.tracks[0]
    let ids = vocal.channel.inserts.map(\.id)
    window.moveInserts([ids[2]], before: ids[0], on: vocal.id)
    #expect(window.project.tracks[0].channel.inserts.map(\.name) == ["Verb", "EQ", "Comp"])
    window.moveInserts([ids[2]], before: nil, on: vocal.id)
    #expect(window.project.tracks[0].channel.inserts.map(\.name) == ["EQ", "Comp", "Verb"])
    window.moveInserts([ids[0]], before: ids[1], on: vocal.id)
    #expect(window.project.tracks[0].channel.inserts.map(\.name) == ["EQ", "Comp", "Verb"], "Dropped where it was: nothing to do")
  }

  @Test func newVCAsAreNumberedAndTakeTheSelection() throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let tracks = window.project.tracks
    window.addVCA(assigning: [tracks[0].id])
    window.addVCA(assigning: [])
    #expect(window.project.vcas.map(\.name) == ["VCA 1", "VCA 2"])
    let second = window.project.vcas[1].id
    window.selectedTrackIDs = [tracks[1].id, tracks[2].id]
    window.assignVCA(second, to: tracks[1].id)
    #expect(window.project.tracks.map(\.channel.vcaID) == [window.project.vcas[0].id, second, second])
    window.setVCA(second, actionName: "VCA Volume") { $0.volume = -4 }
    #expect(window.project.mixingFoldersAndVCAs().tracks[2].channel.volume == -4)
  }

  @Test func folderStacksAreMadeFromTheSelection() throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.selectedTrackIDs = Set(window.project.tracks.prefix(2).map(\.id))
    window.createStack(folder: true)
    let folder = try #require(window.project.tracks.first)
    #expect(folder.isFolderStack && folder.name == "Folder")
    #expect(window.selectedTrackID == folder.id)
    // A track added inside the folder joins it but keeps Stereo Out.
    window.addTrack(.audio)
    let added = try #require(window.project.tracks.first { $0.id == window.selectedTrackID })
    #expect(added.stackID == folder.id && added.channel.output == .stereoOut)
    #expect(window.outputDestinations(for: added.id).isEmpty, "A folder isn't somewhere to send audio")
  }
}
