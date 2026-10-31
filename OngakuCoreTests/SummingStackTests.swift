//
//  SummingStackTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Track outputs and Logic-style summing stacks.
struct SummingStackTests {
  private let drums = Track(name: "Drums", kind: .softwareInstrument)
  private let bass = Track(name: "Bass", kind: .softwareInstrument)
  private let keys = Track(name: "Keys", kind: .softwareInstrument)
  private let reverb = Track(name: "Reverb", kind: .aux)
  private let stack = Track(name: "Rhythm", kind: .aux)

  private var project: Project { Project(tracks: [drums, keys, bass, reverb]) }

  /// Drums and Bass in a stack; Keys stays outside.
  private func stacked() throws -> Project {
    var project = project
    try CreateSummingStack([drums.id, bass.id], stack: stack).apply(to: &project)
    return project
  }

  @Test func creatingAStackGathersTheTracksUnderIt() throws {
    let project = try stacked()
    #expect(project.tracks.map(\.name) == ["Rhythm", "Drums", "Bass", "Keys", "Reverb"])
    #expect(project.tracks[0].isSummingStack)
    #expect(project.stackMembers(of: stack.id).map(\.name) == ["Drums", "Bass"])
    #expect(project.stackMembers(of: stack.id).allSatisfy { $0.channel.output == .track(stack.id) })
    #expect(project.tracks[0].channel.output == .stereoOut)
    #expect(project.track(withID: keys.id)?.channel.output == .stereoOut)
  }

  @Test func stacksDontNest() throws {
    var project = try stacked()
    let outer = Track(name: "Outer", kind: .aux)
    #expect(throws: EditError.self) { try CreateSummingStack([drums.id, keys.id], stack: outer).apply(to: &project) }
    #expect(throws: EditError.self) { try CreateSummingStack([stack.id], stack: outer).apply(to: &project) }
  }

  @Test func flatteningRoutesSubtracksWhereTheStackWent() throws {
    var project = try stacked()
    try SetTrackOutput(stack.id, to: .track(reverb.id)).apply(to: &project)
    try AddSend(Send(destinationTrackID: stack.id), from: keys.id).apply(to: &project)
    try FlattenStack(stack.id).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Drums", "Bass", "Keys", "Reverb"])
    #expect(project.track(withID: drums.id)?.channel.output == .track(reverb.id))
    #expect(project.track(withID: drums.id)?.stackID == nil)
    #expect(project.track(withID: keys.id)?.channel.sends.isEmpty == true, "Sends to the stack go with it")
  }

  @Test func deletingAStackDeletesItsSubtracks() throws {
    var project = try stacked()
    try DeleteTracks([stack.id]).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Keys", "Reverb"])
  }

  @Test func deletingAnAuxSendsItsInputsToStereoOut() throws {
    var project = project
    try SetTrackOutput(keys.id, to: .track(reverb.id)).apply(to: &project)
    try DeleteTracks([reverb.id]).apply(to: &project)
    #expect(project.track(withID: keys.id)?.channel.output == .stereoOut)
  }

  @Test func outputsGoToAuxesWithoutLoops() throws {
    var project = try stacked()
    #expect(throws: EditError.self, "Not to an instrument track") {
      try SetTrackOutput(keys.id, to: .track(bass.id)).apply(to: &project)
    }
    #expect(throws: EditError.self, "Not to itself") {
      try SetTrackOutput(reverb.id, to: .track(reverb.id)).apply(to: &project)
    }
    try SetTrackOutput(reverb.id, to: .track(stack.id)).apply(to: &project)
    #expect(throws: EditError.self, "The stack sending to the reverb that feeds it would loop") {
      try AddSend(Send(destinationTrackID: reverb.id), from: stack.id).apply(to: &project)
    }
  }

  @Test func routingASubtrackElsewhereTakesItOutOfTheStack() throws {
    var project = try stacked()
    try SetTrackOutput(bass.id, to: .stereoOut).apply(to: &project)
    #expect(project.track(withID: bass.id)?.stackID == nil)
    #expect(project.stackMembers(of: stack.id).map(\.name) == ["Drums"])
  }

  @Test func soloingAStackPlaysItsSubtracks() throws {
    var project = try stacked()
    let index = try #require(project.trackIndex(for: stack.id))
    project.tracks[index].channel.isSoloed = true
    #expect(project.isTrackAudible(drums.id))
    #expect(project.isTrackAudible(bass.id))
    #expect(!project.isTrackAudible(keys.id))
  }

  @Test func soloingASubtrackKeepsItsStack() throws {
    var project = try stacked()
    let index = try #require(project.trackIndex(for: drums.id))
    project.tracks[index].channel.isSoloed = true
    #expect(project.isTrackAudible(stack.id))
    #expect(!project.isTrackAudible(bass.id), "The other subtracks are still silenced")
  }

  @Test func aStackMovesWithItsSubtracks() throws {
    var project = try stacked()
    try MoveTrack(stack.id, to: 2).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Keys", "Reverb", "Rhythm", "Drums", "Bass"])
  }

  @Test func newSubtracksMustOutputToTheirStack() throws {
    var project = try stacked()
    let loose = Track(name: "Loose", kind: .audio, stackID: stack.id)
    #expect(throws: EditError.self) { try AddTrack(loose).apply(to: &project) }
    var joined = loose
    joined.channel.output = .track(stack.id)
    try AddTrack(joined, at: 3).apply(to: &project)
    #expect(project.stackMembers(of: stack.id).map(\.name) == ["Drums", "Bass", "Loose"])
  }

  @Test func stacksAreSavedWithTheProject() throws {
    let project = try stacked()
    #expect(try ProjectArchive.decode(ProjectArchive.encode(project)) == project)
  }

  @Test func olderChannelStripsGoToStereoOut() throws {
    let json = Data(#"{"volume":0,"pan":0,"isMuted":false,"isSoloed":false}"#.utf8)
    #expect(try JSONDecoder().decode(ChannelStrip.self, from: json).output == .stereoOut)
  }
}
