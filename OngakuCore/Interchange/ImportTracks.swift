//
//  ImportTracks.swift
//  OngakuCore
//

import Foundation

/// Adds tracks read from an interchange file, such as a MIDI file, as one undoable step.
public struct ImportTracks: EditCommand {
  public var tracks: [Track]
  /// Replaces the project's tempo and meter when set, for example when importing a MIDI file
  /// into an empty project.
  public var tempoMap: TempoMap?
  /// Where the first imported track goes; `nil` appends.
  public var index: Int?

  /// Replaces the project's key and key changes when set, as `tempoMap` does the tempo.
  public var keys: (start: KeySignature, changes: [KeyChange])?

  public init(_ tracks: [Track], tempoMap: TempoMap? = nil, keys: (start: KeySignature, changes: [KeyChange])? = nil, at index: Int? = nil) {
    self.tracks = tracks
    self.tempoMap = tempoMap
    self.keys = keys
    self.index = index
  }

  public var actionName: String { tracks.count == 1 ? "Import Track" : "Import Tracks" }

  public func apply(to project: inout Project) throws {
    if let tempoMap {
      project.tempoMap = tempoMap
    }
    if let keys {
      project.keySignature = keys.start
      project.keyChanges = keys.changes
      project.sortKeyChanges()
      project.removeRedundantKeyChanges()
    }
    var insertionIndex = min(max(index ?? project.tracks.count, 0), project.tracks.count)
    for track in tracks {
      try AddTrack(track, at: insertionIndex).apply(to: &project)
      insertionIndex += 1
    }
    // Make sure the project is long enough to show everything that was imported.
    project.extendEndPastContent()
  }
}

extension Project {
  /// Whether the project has no regions yet, so an import can take over its tempo.
  public var hasNoRegions: Bool {
    tracks.allSatisfy(\.regions.isEmpty)
  }
}
