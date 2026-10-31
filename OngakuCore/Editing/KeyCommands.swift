//
//  KeyCommands.swift
//  OngakuCore
//

import Foundation

/// Sets the key from a position: the song's key at the start, or a key change (added, or
/// replacing the one already there).
public struct SetKey: EditCommand {
  public var key: KeySignature
  public var position: Tick

  public init(_ key: KeySignature, at position: Tick) {
    self.key = key
    self.position = position
  }

  public var actionName: String { position <= .zero ? "Key Signature Change" : "Key Change" }

  public func apply(to project: inout Project) throws {
    if position <= .zero {
      project.keySignature = key
    } else if let index = project.keyChanges.firstIndex(where: { $0.position == position }) {
      project.keyChanges[index].key = key
    } else {
      project.keyChanges.append(KeyChange(position: position, key: key))
      project.sortKeyChanges()
    }
    project.removeRedundantKeyChanges()
    // Players use the key's chord where the Chord track has none.
    project.renderPlayerRegions()
  }
}

/// Moves a key change to another position (after the start of the song).
public struct MoveKeyChange: EditCommand {
  public var changeID: KeyChange.ID
  public var position: Tick

  public init(_ changeID: KeyChange.ID, to position: Tick) {
    self.changeID = changeID
    self.position = position
  }

  public var actionName: String { "Move Key Change" }

  public func apply(to project: inout Project) throws {
    guard project.keyChanges.contains(where: { $0.id == changeID }) else {
      throw EditError.invalidValue("That key change isn't in the song.")
    }
    guard position > .zero else {
      throw EditError.invalidValue("The key at the start of the song is changed on the LCD or by clicking it.")
    }
    // One that was already there gives way.
    project.keyChanges.removeAll { $0.position == position && $0.id != changeID }
    if let index = project.keyChanges.firstIndex(where: { $0.id == changeID }) {
      project.keyChanges[index].position = position
    }
    project.sortKeyChanges()
    project.removeRedundantKeyChanges()
    project.renderPlayerRegions()
  }
}

/// Removes key changes: the key before them carries on.
public struct RemoveKeyChanges: EditCommand {
  public var changeIDs: Set<KeyChange.ID>

  public init(_ changeIDs: Set<KeyChange.ID>) {
    self.changeIDs = changeIDs
  }

  public var actionName: String { changeIDs.count == 1 ? "Delete Key Change" : "Delete Key Changes" }

  public func apply(to project: inout Project) throws {
    project.keyChanges.removeAll { changeIDs.contains($0.id) }
    project.removeRedundantKeyChanges()
    project.renderPlayerRegions()
  }
}

extension Project {
  /// A change to the key already in effect changes nothing, so it goes (as in Logic).
  mutating func removeRedundantKeyChanges() {
    var previous = keySignature
    keyChanges = keyChanges.filter { change in
      defer { previous = change.key }
      return change.key != previous
    }
  }
}
