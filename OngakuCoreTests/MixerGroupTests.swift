//
//  MixerGroupTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Mixer groups: grouped tracks move together for the properties the group links.
struct MixerGroupTests {
  /// Drums at -6 dB and Bass at -10 dB in group 1, Keys on its own.
  private func project(group: MixerGroup = MixerGroup(id: 1)) throws -> (Project, drums: Track.ID, bass: Track.ID, keys: Track.ID) {
    let drums = Track(name: "Drums", kind: .softwareInstrument, channel: ChannelStrip(volume: -6))
    let bass = Track(name: "Bass", kind: .softwareInstrument, channel: ChannelStrip(volume: -10, pan: 0.5))
    let keys = Track(name: "Keys", kind: .softwareInstrument)
    var project = Project(tracks: [drums, bass, keys])
    try CreateMixerGroup(group, with: [drums.id, bass.id]).apply(to: &project)
    return (project, drums.id, bass.id, keys.id)
  }

  private func channel(_ project: Project, _ id: Track.ID) -> ChannelStrip {
    project.track(withID: id)!.channel
  }

  @Test func volumeMovesEveryMemberByTheSameAmount() throws {
    var (project, drums, bass, keys) = try project()
    var changed = channel(project, drums)
    changed.volume = -3
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).volume == -7, "Bass keeps its 4 dB below Drums")
    #expect(channel(project, keys).volume == 0, "Keys isn't in the group")
  }

  @Test func muteAndSoloSwitchTogether() throws {
    var (project, drums, bass, _) = try project()
    var changed = channel(project, drums)
    changed.isMuted = true
    changed.isSoloed = true
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).isMuted)
    #expect(channel(project, bass).isSoloed)
  }

  @Test func onlyLinkedPropertiesMove() throws {
    var (project, drums, bass, _) = try project()
    var changed = channel(project, drums)
    changed.pan = -1
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).pan == 0.5, "Pan isn't linked by default")

    try UpdateMixerGroup(MixerGroup(id: 1, linksPan: true)).apply(to: &project)
    changed.pan = -0.5
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).pan == 1, "0.5 more to the right, kept within range")
  }

  @Test func aGroupThatsOffLinksNothing() throws {
    var (project, drums, bass, _) = try project(group: MixerGroup(id: 1, isEnabled: false))
    var changed = channel(project, drums)
    changed.volume = 0
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).volume == -10)
  }

  @Test func volumesStayInRange() throws {
    var (project, drums, bass, _) = try project()
    var changed = channel(project, drums)
    changed.volume = 6
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).volume == 2)
    changed.volume = -96
    try SetGroupedChannelStrip(drums, to: changed).apply(to: &project)
    #expect(channel(project, bass).volume == -96)
  }

  @Test func deletingAGroupUngroupsItsTracks() throws {
    var (project, drums, _, _) = try project()
    #expect(project.nextGroupNumber == 2)
    try DeleteMixerGroup(1).apply(to: &project)
    #expect(project.groups.isEmpty)
    #expect(project.track(withID: drums)?.groupID == nil)
    #expect(throws: EditError.self) { try SetTrackGroup(5, for: [drums]).apply(to: &project) }
  }

  @Test func groupsAreSaved() throws {
    let (project, drums, _, _) = try project(group: MixerGroup(id: 3, name: "Rhythm", linksPan: true))
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened.groups == project.groups)
    #expect(reopened.track(withID: drums)?.groupID == 3)
  }
}
