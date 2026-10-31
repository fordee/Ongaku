//
//  TrackCommands.swift
//  OngakuCore
//

import Foundation

public struct AddTrack: EditCommand {
  public var track: Track
  /// Insertion index; `nil` appends the track.
  public var index: Int?

  public init(_ track: Track, at index: Int? = nil) {
    self.track = track
    self.index = index
  }

  public var actionName: String { "New Track" }

  public func apply(to project: inout Project) throws {
    guard project.trackIndex(for: track.id) == nil else { throw EditError.duplicateID(track.id) }
    if track.kind != .softwareInstrument, track.channel.instrument != nil {
      throw EditError.invalidValue("Only software instrument tracks can have an instrument.")
    }
    if let stackID = track.stackID {
      guard project.track(withID: stackID)?.isSummingStack == true, track.channel.output == .track(stackID), !track.isSummingStack else {
        throw EditError.invalidValue("A subtrack must output to its summing stack.")
      }
    }
    try validateOutput(track.channel.output, of: track.id, in: project)
    let insertionIndex = min(max(index ?? project.tracks.count, 0), project.tracks.count)
    project.tracks.insert(track, at: insertionIndex)
  }
}

public struct DeleteTracks: EditCommand {
  public var trackIDs: Set<Track.ID>

  public init(_ trackIDs: Set<Track.ID>) {
    self.trackIDs = trackIDs
  }

  public var actionName: String { trackIDs.count == 1 ? "Delete Track" : "Delete Tracks" }

  public func apply(to project: inout Project) throws {
    for trackID in trackIDs {
      _ = try project.requireTrackIndex(trackID)
    }
    // As in Logic, deleting a summing stack deletes its subtracks too.
    let deleted = trackIDs.union(project.tracks.filter { $0.stackID.map(trackIDs.contains) == true }.map(\.id))
    project.tracks.removeAll { deleted.contains($0.id) }
    // Sends to a deleted aux track go with it, and tracks that output to it go to Stereo Out.
    for index in project.tracks.indices {
      project.tracks[index].channel.sends.removeAll { deleted.contains($0.destinationTrackID) }
      if let destination = project.tracks[index].channel.output.trackID, deleted.contains(destination) {
        project.tracks[index].channel.output = .stereoOut
      }
    }
  }
}

public struct MoveTrack: EditCommand {
  public var trackID: Track.ID
  /// The index the track ends up at.
  public var destinationIndex: Int

  public init(_ trackID: Track.ID, to destinationIndex: Int) {
    self.trackID = trackID
    self.destinationIndex = destinationIndex
  }

  public var actionName: String { "Move Track" }

  /// A summing stack moves with its subtracks.
  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    let track = project.tracks[index]
    let moving = [track] + (track.isSummingStack ? project.stackMembers(of: track.id) : [])
    let movingIDs = Set(moving.map(\.id))
    let remaining = project.tracks.filter { !movingIDs.contains($0.id) }
    // As before stacks: the index among the tracks left once the moving ones are taken out.
    let before = min(max(destinationIndex, 0), remaining.count)
    project.tracks = Array(remaining[..<before]) + moving + Array(remaining[before...])
  }
}

public struct RenameTrack: EditCommand {
  public var trackID: Track.ID
  public var name: String

  public init(_ trackID: Track.ID, to name: String) {
    self.trackID = trackID
    self.name = name
  }

  public var actionName: String { "Rename Track" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw EditError.invalidValue("A track name can’t be empty.") }
    project.tracks[index].name = trimmed
  }
}

public struct SetTrackColor: EditCommand {
  public var trackID: Track.ID
  public var color: TrackColor

  public init(_ trackID: Track.ID, to color: TrackColor) {
    self.trackID = trackID
    self.color = color
  }

  public var actionName: String { "Track Color" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    project.tracks[index].color = color
  }
}

/// Replaces a track's channel strip. Volume and pan are clamped to their ranges.
public struct SetChannelStrip: EditCommand {
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
    if project.tracks[index].kind != .softwareInstrument, channel.instrument != nil {
      throw EditError.invalidValue("Only software instrument tracks can have an instrument.")
    }
    for send in channel.sends {
      try validateSend(send, from: project.tracks[index].id, in: project)
    }
    try validateOutput(channel.output, of: trackID, in: project)
    guard channel.inserts.count <= ChannelStrip.maximumInserts else {
      throw EditError.invalidValue("A channel strip has at most \(ChannelStrip.maximumInserts) inserts.")
    }
    project.tracks[index].channel = channel.clamped()
  }
}
