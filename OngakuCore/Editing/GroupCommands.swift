//
//  GroupCommands.swift
//  OngakuCore
//

import Foundation

/// Creates a mixer group and puts tracks in it.
public struct CreateMixerGroup: EditCommand {
  public var group: MixerGroup
  public var trackIDs: Set<Track.ID>

  public init(_ group: MixerGroup, with trackIDs: Set<Track.ID>) {
    self.group = group
    self.trackIDs = trackIDs
  }

  public var actionName: String { "New Group" }

  public func apply(to project: inout Project) throws {
    guard MixerGroup.numbers.contains(group.id), project.mixerGroup(withID: group.id) == nil else {
      throw EditError.invalidValue("Group \(group.id) is already in use.")
    }
    project.groups.append(group)
    project.groups.sort { $0.id < $1.id }
    try SetTrackGroup(group.id, for: trackIDs).apply(to: &project)
  }
}

/// Changes a group's name, links or whether it's on.
public struct UpdateMixerGroup: EditCommand {
  public var group: MixerGroup
  public var actionName: String

  public init(_ group: MixerGroup, actionName: String = "Change Group") {
    self.group = group
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    guard let index = project.groups.firstIndex(where: { $0.id == group.id }) else {
      throw EditError.invalidValue("The group no longer exists.")
    }
    project.groups[index] = group
  }
}

/// Deletes a group; its tracks are left ungrouped.
public struct DeleteMixerGroup: EditCommand {
  public var groupID: Int

  public init(_ groupID: Int) {
    self.groupID = groupID
  }

  public var actionName: String { "Delete Group" }

  public func apply(to project: inout Project) throws {
    project.groups.removeAll { $0.id == groupID }
    for index in project.tracks.indices where project.tracks[index].groupID == groupID {
      project.tracks[index].groupID = nil
    }
  }
}

/// Puts tracks in a group, or takes them out of their group (`nil`).
public struct SetTrackGroup: EditCommand {
  public var groupID: Int?
  public var trackIDs: Set<Track.ID>

  public init(_ groupID: Int?, for trackIDs: Set<Track.ID>) {
    self.groupID = groupID
    self.trackIDs = trackIDs
  }

  public var actionName: String { groupID == nil ? "Remove from Group" : "Assign Group" }

  public func apply(to project: inout Project) throws {
    if let groupID, project.mixerGroup(withID: groupID) == nil {
      throw EditError.invalidValue("Group \(groupID) doesn’t exist.")
    }
    for trackID in trackIDs {
      let index = try project.requireTrackIndex(trackID)
      project.tracks[index].groupID = groupID
    }
  }
}

/// Changes a channel strip and, through its mixer group, the other members: volume and pan
/// by the same amount (each staying within its range), mute and solo to the same setting.
/// Everything else applies to the one track only.
public struct SetGroupedChannelStrip: EditCommand {
  public var trackID: Track.ID
  public var channel: ChannelStrip
  public var actionName: String

  public init(_ trackID: Track.ID, to channel: ChannelStrip, actionName: String = "Channel Strip Change") {
    self.trackID = trackID
    self.channel = channel
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    let old = project.tracks[index].channel
    try SetChannelStrip(trackID, to: channel, actionName: actionName).apply(to: &project)
    guard let (group, partners) = project.groupPartners(of: trackID) else { return }
    let new = project.tracks[index].channel
    for partner in partners {
      var linked = partner.channel
      if group.linksVolume, new.volume != old.volume {
        linked.volume += new.volume - old.volume
      }
      if group.linksPan, new.pan != old.pan {
        linked.pan += new.pan - old.pan
      }
      if group.linksMute, new.isMuted != old.isMuted {
        linked.isMuted = new.isMuted
      }
      if group.linksSolo, new.isSoloed != old.isSoloed {
        linked.isSoloed = new.isSoloed
      }
      if linked != partner.channel {
        try SetChannelStrip(partner.id, to: linked.clamped(), actionName: actionName).apply(to: &project)
      }
    }
  }
}
