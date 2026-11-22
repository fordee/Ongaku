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
      guard let stack = project.track(withID: stackID), stack.isStack, !track.isStack else {
        throw EditError.invalidValue("A subtrack must belong to a stack.")
      }
      guard !stack.isSummingStack || track.channel.output == .track(stackID) else {
        throw EditError.invalidValue("A subtrack must output to its summing stack.")
      }
    }
    try validateOutput(track.channel.output, of: track.id, in: project)
    let insertionIndex = min(max(index ?? project.tracks.count, 0), project.tracks.count)
    project.tracks.insert(track, at: insertionIndex)
  }
}

/// Adds an aux track for each output of a track's instrument after its first, as Logic's
/// "+" on a multi-output instrument does, each named for its output. Outputs that already
/// have one are left alone.
public struct AddInstrumentOutputs: EditCommand {
  public var trackID: Track.ID
  /// The instrument's outputs after its first, by name (output 1 first).
  public var outputNames: [String]
  /// The new tracks' IDs, one per output, so redoing makes the same tracks.
  public var newTrackIDs: [Track.ID]

  public init(of trackID: Track.ID, outputNames: [String]) {
    self.trackID = trackID
    self.outputNames = outputNames
    newTrackIDs = outputNames.map { _ in UUID() }
  }

  public var actionName: String { "Add Instrument Outputs" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    let track = project.tracks[index]
    guard track.kind == .softwareInstrument else {
      throw EditError.trackKindMismatch(expected: .softwareInstrument, found: track.kind)
    }
    let existing = Set(project.tracks.compactMap { $0.channel.instrumentOutput }.filter { $0.trackID == trackID }.map(\.bus))
    // After the instrument track and any outputs it already has.
    var insertion = index + 1
    while insertion < project.tracks.count, project.tracks[insertion].channel.instrumentOutput?.trackID == trackID {
      insertion += 1
    }
    for (offset, name) in outputNames.enumerated() where !existing.contains(offset + 1) {
      var aux = Track(id: newTrackIDs[offset], name: "\(track.name) \(name)", kind: .aux)
      aux.channel.instrumentOutput = InstrumentOutput(trackID: trackID, bus: offset + 1)
      project.tracks.insert(aux, at: insertion)
      insertion += 1
    }
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
    // As in Logic, deleting a stack deletes its subtracks too.
    let deleted = trackIDs.union(project.tracks.filter { $0.stackID.map(trackIDs.contains) == true }.map(\.id))
    project.tracks.removeAll { deleted.contains($0.id) }
    // Sends to a deleted aux track go with it, and tracks that output to it go to Stereo Out.
    for index in project.tracks.indices {
      project.tracks[index].channel.sends.removeAll { deleted.contains($0.destinationTrackID) }
      if let destination = project.tracks[index].channel.output.trackID, deleted.contains(destination) {
        project.tracks[index].channel.output = .stereoOut
      }
    }
    // Side chains a deleted track fed are switched off.
    project = project.droppingMissingSidechains()
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
    let moving = [track] + (track.isStack ? project.stackMembers(of: track.id) : [])
    let movingIDs = Set(moving.map(\.id))
    let remaining = project.tracks.filter { !movingIDs.contains($0.id) }
    // As before stacks: the index among the tracks left once the moving ones are taken out.
    let before = min(max(destinationIndex, 0), remaining.count)
    project.tracks = Array(remaining[..<before]) + moving + Array(remaining[before...])
  }
}

extension Project {
  /// Where `MoveTrack` should put a track dropped just above `targetID` (or below the last
  /// track, for `nil`), as dragging a track header does; `nil` if it wouldn't move. Stacks
  /// stay whole: a subtrack moves only within its stack, and another track dropped among a
  /// stack's subtracks goes after them.
  public func trackMoveDestination(of trackID: Track.ID, before targetID: Track.ID?) -> Int? {
    guard let track = track(withID: trackID) else { return nil }
    let moving = Set([trackID] + (track.isStack ? stackMembers(of: trackID).map(\.id) : []))
    if let targetID, moving.contains(targetID) { return nil }
    let remaining = tracks.filter { !moving.contains($0.id) }
    var destination = targetID.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.count

    if let stackID = track.stackID {
      // A subtrack: somewhere from just under its stack to just after its last subtrack.
      guard let stackIndex = remaining.firstIndex(where: { $0.id == stackID }) else { return nil }
      let lastMember = remaining.lastIndex { $0.stackID == stackID } ?? stackIndex
      destination = min(max(destination, stackIndex + 1), lastMember + 1)
    } else if destination < remaining.count, let stackID = remaining[destination].stackID,
      let lastMember = remaining.lastIndex(where: { $0.stackID == stackID })
    {
      // Dropped among a stack's subtracks: after them.
      destination = lastMember + 1
    }
    // A stack's subtracks follow it, so its index alone says whether it moves.
    guard tracks.firstIndex(where: { $0.id == trackID }) != destination else { return nil }
    return destination
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

/// Hides tracks from the tracks area, or shows them again, as Logic's Hide Track does.
/// Hidden tracks still play.
public struct SetTracksHidden: EditCommand {
  public var trackIDs: Set<Track.ID>
  public var isHidden: Bool

  public init(_ trackIDs: Set<Track.ID>, isHidden: Bool) {
    self.trackIDs = trackIDs
    self.isHidden = isHidden
  }

  public var actionName: String {
    let noun = trackIDs.count == 1 ? "Track" : "Tracks"
    return isHidden ? "Hide \(noun)" : "Show \(noun)"
  }

  public func apply(to project: inout Project) throws {
    for id in trackIDs {
      let index = try project.requireTrackIndex(id)
      project.tracks[index].isHidden = isHidden
    }
  }
}
