//
//  StackCommands.swift
//  OngakuCore
//

import Foundation

/// Groups tracks into a summing stack, as Logic's Track › Create Track Stack › Summing
/// Stack: a new aux track (the stack's main track) goes where the first of them was, they
/// follow it as its subtracks, in their order, and their outputs go to it, so its fader,
/// inserts, sends and mute work on them all together.
public struct CreateSummingStack: EditCommand {
  public var trackIDs: Set<Track.ID>
  /// The new main track. Its kind must be aux; it's marked as a stack here.
  public var stack: Track

  public init(_ trackIDs: Set<Track.ID>, stack: Track) {
    self.trackIDs = trackIDs
    self.stack = stack
  }

  public var actionName: String { "Create Summing Stack" }

  public func apply(to project: inout Project) throws {
    guard !trackIDs.isEmpty else { throw EditError.invalidValue("Select the tracks to put in the stack.") }
    guard stack.kind == .aux, stack.regions.isEmpty else {
      throw EditError.invalidValue("A summing stack's main track must be an aux track.")
    }
    guard project.trackIndex(for: stack.id) == nil else { throw EditError.duplicateID(stack.id) }
    var members: [Track] = []
    for track in project.tracks where trackIDs.contains(track.id) {
      guard !track.isSummingStack, track.stackID == nil else {
        throw EditError.invalidValue("“\(track.name)” is already part of a summing stack.")
      }
      members.append(track)
    }
    guard members.count == trackIDs.count else {
      throw EditError.trackNotFound(trackIDs.first { project.trackIndex(for: $0) == nil } ?? stack.id)
    }

    // The stack goes where the members were going, if they all agreed; otherwise Stereo Out.
    var stack = stack
    stack.isSummingStack = true
    stack.stackID = nil
    let outputs = Set(members.map(\.channel.output))
    stack.channel.output = outputs.count == 1 ? outputs.first ?? .stereoOut : .stereoOut

    let insertionIndex = project.tracks.firstIndex { trackIDs.contains($0.id) } ?? project.tracks.count
    let before = project.tracks[..<insertionIndex].filter { !trackIDs.contains($0.id) }
    let after = project.tracks[insertionIndex...].filter { !trackIDs.contains($0.id) }
    let subtracks = members.map { member in
      var subtrack = member
      subtrack.stackID = stack.id
      subtrack.channel.output = .track(stack.id)
      return subtrack
    }
    project.tracks = before + [stack] + subtracks + after
  }
}

/// Takes a summing stack apart, as Logic's Flatten Stack: the subtracks become ordinary
/// tracks that output where the stack did, and the stack's main track goes.
public struct FlattenStack: EditCommand {
  public var stackID: Track.ID

  public init(_ stackID: Track.ID) {
    self.stackID = stackID
  }

  public var actionName: String { "Flatten Stack" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(stackID)
    let stack = project.tracks[index]
    guard stack.isSummingStack else { throw EditError.invalidValue("“\(stack.name)” isn’t a summing stack.") }
    for memberIndex in project.tracks.indices where project.tracks[memberIndex].channel.output == .track(stackID) {
      project.tracks[memberIndex].channel.output = stack.channel.output
      if project.tracks[memberIndex].stackID == stackID {
        project.tracks[memberIndex].stackID = nil
      }
    }
    project.tracks.remove(at: index)
    for trackIndex in project.tracks.indices {
      project.tracks[trackIndex].channel.sends.removeAll { $0.destinationTrackID == stackID }
    }
  }
}

/// Chooses where a track's output goes: Stereo Out or an aux track. A subtrack routed
/// somewhere other than its stack leaves the stack.
public struct SetTrackOutput: EditCommand {
  public var trackID: Track.ID
  public var output: ChannelOutput

  public init(_ trackID: Track.ID, to output: ChannelOutput) {
    self.trackID = trackID
    self.output = output
  }

  public var actionName: String { "Change Output" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    try validateOutput(output, of: trackID, in: project)
    project.tracks[index].channel.output = output
    if let stackID = project.tracks[index].stackID, output != .track(stackID) {
      project.tracks[index].stackID = nil
    }
  }
}

/// An output must be Stereo Out or an aux track, and mustn't feed back into the track.
func validateOutput(_ output: ChannelOutput, of trackID: Track.ID, in project: Project) throws {
  guard let destinationID = output.trackID else { return }
  guard let destination = project.track(withID: destinationID) else { throw EditError.trackNotFound(destinationID) }
  guard destination.kind == .aux else { throw EditError.invalidValue("A track can only output to Stereo Out or an aux track.") }
  guard project.track(withID: trackID)?.channel.sends.contains(where: { $0.destinationTrackID == destinationID }) != true else {
    throw EditError.invalidValue("This track already sends to “\(destination.name)”; remove the send first.")
  }
  // Ignore the track's current output when checking for loops.
  var withoutOutput = project
  if let index = withoutOutput.trackIndex(for: trackID) {
    withoutOutput.tracks[index].channel.output = .stereoOut
  }
  guard !withoutOutput.outputWouldCreateFeedback(from: trackID, to: destinationID) else {
    throw EditError.invalidValue("That output would feed “\(destination.name)” back into itself.")
  }
}
