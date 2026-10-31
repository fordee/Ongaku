//
//  EditCommand.swift
//  OngakuCore
//

import Foundation

/// A single, named change to a project.
///
/// Every change the user makes goes through a command. That gives one place to validate
/// edits, a name for the Undo menu, and a vocabulary that scripting, MIDI-learn or
/// collaboration features can reuse later. New features add new command types; nothing else
/// has to change.
///
/// `apply(to:)` may throw part-way through. `ProjectEditor` always applies commands to a copy,
/// so a failed command never leaves the project half-edited.
public protocol EditCommand: Sendable {
  /// Shown in the Edit menu as "Undo <actionName>".
  var actionName: String { get }
  func apply(to project: inout Project) throws
}

public enum EditError: Error, Equatable, LocalizedError {
  case trackNotFound(Track.ID)
  case regionNotFound(Region.ID)
  case noteNotFound(MIDINote.ID)
  case controlEventNotFound(MIDIControlEvent.ID)
  case audioFileNotFound(AudioFileReference.ID)
  case duplicateID(UUID)
  case trackKindMismatch(expected: TrackKind, found: TrackKind)
  case invalidValue(String)

  public var errorDescription: String? {
    switch self {
    case .trackNotFound: "The track no longer exists."
    case .regionNotFound: "The region no longer exists."
    case .noteNotFound: "The note no longer exists."
    case .controlEventNotFound: "The controller event no longer exists."
    case .audioFileNotFound: "The audio file is missing from the project."
    case .duplicateID: "An item with the same identifier already exists."
    case .trackKindMismatch(let expected, let found):
      "This needs a \(expected.displayName) track, not a \(found.displayName) track."
    case .invalidValue(let message): message
    }
  }
}

/// Applies several commands as one undoable step, for example moving a multi-selection.
public struct CompositeCommand: EditCommand {
  public var actionName: String
  public var commands: [any EditCommand]

  public init(_ actionName: String, commands: [any EditCommand]) {
    self.actionName = actionName
    self.commands = commands
  }

  public func apply(to project: inout Project) throws {
    for command in commands {
      try command.apply(to: &project)
    }
  }
}

// MARK: - Helpers shared by commands

extension Project {
  func requireTrackIndex(_ trackID: Track.ID) throws -> Int {
    guard let index = trackIndex(for: trackID) else { throw EditError.trackNotFound(trackID) }
    return index
  }

  func requireRegionLocation(_ regionID: Region.ID) throws -> (track: Int, region: Int) {
    guard let location = regionLocation(for: regionID) else { throw EditError.regionNotFound(regionID) }
    return location
  }

  /// How many frames of an audio file play between two timeline positions.
  func audioFrames(from start: Tick, to end: Tick, fileID: AudioFileReference.ID) throws -> Int64 {
    guard let file = audioFile(withID: fileID) else { throw EditError.audioFileNotFound(fileID) }
    let seconds = tempoMap.seconds(at: end) - tempoMap.seconds(at: start)
    return Int64((seconds * file.sampleRate).rounded())
  }
}
