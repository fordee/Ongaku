//
//  ChordCommands.swift
//  OngakuCore
//

import Foundation

// Every change to the Chord track plays the session players' regions again, so they follow.

/// Puts a chord on the Chord track at a position (replacing one already there).
public struct SetChord: EditCommand {
  public var position: Tick
  public var chord: Chord
  public var id: UUID

  public init(_ chord: Chord, at position: Tick, id: UUID = UUID()) {
    self.chord = chord
    self.position = position
    self.id = id
  }

  public var actionName: String { "Set Chord" }

  public func apply(to project: inout Project) throws {
    guard position >= .zero else { throw EditError.invalidValue("A chord can't start before the song.") }
    if let index = project.chords.firstIndex(where: { $0.position == position }) {
      project.chords[index].chord = chord
    } else {
      project.chords.append(ChordChange(id: id, position: position, chord: chord))
      project.chords.sort { $0.position < $1.position }
    }
    project.renderPlayerRegions()
  }
}

/// Moves a chord to another position (replacing one there).
public struct MoveChord: EditCommand {
  public var id: UUID
  public var position: Tick

  public init(_ id: UUID, to position: Tick) {
    self.id = id
    self.position = position
  }

  public var actionName: String { "Move Chord" }

  public func apply(to project: inout Project) throws {
    guard project.chords.contains(where: { $0.id == id }) else {
      throw EditError.invalidValue("That chord isn't on the Chord track.")
    }
    let position = max(.zero, position)
    // A chord already where it lands is replaced.
    project.chords.removeAll { $0.position == position && $0.id != id }
    if let index = project.chords.firstIndex(where: { $0.id == id }) {
      project.chords[index].position = position
    }
    project.chords.sort { $0.position < $1.position }
    project.renderPlayerRegions()
  }
}

public struct DeleteChords: EditCommand {
  public var ids: Set<UUID>

  public init(_ ids: Set<UUID>) {
    self.ids = ids
  }

  public var actionName: String { ids.count == 1 ? "Delete Chord" : "Delete Chords" }

  public func apply(to project: inout Project) throws {
    project.chords.removeAll { ids.contains($0.id) }
    project.renderPlayerRegions()
  }
}

/// Works out the chords in a MIDI region and puts them on the Chord track over the region,
/// replacing the chords there.
public struct DetectChords: EditCommand {
  public var regionID: Region.ID

  public init(from regionID: Region.ID) {
    self.regionID = regionID
  }

  public var actionName: String { "Detect Chords" }

  public func apply(to project: inout Project) throws {
    guard let region = project.region(withID: regionID), case .midi = region.content else {
      throw EditError.invalidValue("Chords can be found in MIDI regions.")
    }
    let found = project.detectChords(in: region)
    guard !found.isEmpty else { throw EditError.invalidValue("There aren't enough notes in “\(region.name)” to tell its chords.") }
    project.chords.removeAll { $0.position >= region.start && $0.position < region.end }
    project.chords += found
    project.chords.sort { $0.position < $1.position }
    project.renderPlayerRegions()
  }
}

/// Writes chords over a stretch of the song (a progression, say), replacing the chords
/// there.
public struct SetChords: EditCommand {
  public var changes: [ChordChange]
  public var start: Tick
  public var end: Tick
  public var actionName: String

  public init(_ changes: [ChordChange], from start: Tick, to end: Tick, actionName: String = "Set Chords") {
    self.changes = changes
    self.start = start
    self.end = end
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    guard end > start else { throw EditError.invalidValue("Choose where the chords go.") }
    project.chords.removeAll { $0.position >= start && $0.position < end }
    project.chords += changes.filter { $0.position >= start && $0.position < end }
    project.chords.sort { $0.position < $1.position }
    project.renderPlayerRegions()
  }
}
