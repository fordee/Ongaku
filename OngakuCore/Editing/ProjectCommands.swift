//
//  ProjectCommands.swift
//  OngakuCore
//

import Foundation

public struct SetTempo: EditCommand {
  public var bpm: Double
  public var position: Tick

  public init(_ bpm: Double, at position: Tick = .zero) {
    self.bpm = bpm
    self.position = position
  }

  public var actionName: String { "Tempo Change" }

  public func apply(to project: inout Project) throws {
    try project.tempoMap.setTempo(bpm, at: position)
  }
}

public struct SetTimeSignature: EditCommand {
  public var signature: TimeSignature
  public var barIndex: Int

  public init(_ signature: TimeSignature, atBarIndex barIndex: Int = 0) {
    self.signature = signature
    self.barIndex = barIndex
  }

  public var actionName: String { "Time Signature Change" }

  public func apply(to project: inout Project) throws {
    try project.tempoMap.setTimeSignature(signature, atBarIndex: barIndex)
    project.renderDrummerRegions()
    project.renderPlayerRegions()
  }
}

public struct SetKeySignature: EditCommand {
  public var keySignature: KeySignature

  public init(_ keySignature: KeySignature) {
    self.keySignature = keySignature
  }

  public var actionName: String { "Key Signature Change" }

  public func apply(to project: inout Project) throws {
    project.keySignature = keySignature
    project.removeRedundantKeyChanges()
    // Players use the key's chord where the Chord track has none.
    project.renderPlayerRegions()
  }
}

public struct SetCycle: EditCommand {
  public var cycle: CycleRange

  public init(_ cycle: CycleRange) {
    self.cycle = cycle
  }

  public var actionName: String { "Cycle Change" }

  public func apply(to project: inout Project) throws {
    guard cycle.start >= .zero, cycle.end > cycle.start else {
      throw EditError.invalidValue("The cycle must end after it starts.")
    }
    project.cycle = cycle
  }
}

/// Switches the metronome on or off. An edit like the cycle's, so it's saved with the song
/// and undone the same way.
public struct SetMetronome: EditCommand {
  public var isEnabled: Bool

  public init(_ isEnabled: Bool) {
    self.isEnabled = isEnabled
  }

  public var actionName: String { "Metronome Change" }

  public func apply(to project: inout Project) throws {
    project.isMetronomeEnabled = isEnabled
  }
}

/// Moves a tempo change and sets its tempo, as dragging a point on Logic's Tempo track
/// does. The first tempo (at the project start) can't move. A change moved onto another one
/// replaces it.
public struct UpdateTempoChange: EditCommand {
  public var oldPosition: Tick
  public var position: Tick
  public var bpm: Double

  public init(at oldPosition: Tick, to position: Tick, bpm: Double) {
    self.oldPosition = oldPosition
    self.position = position
    self.bpm = bpm
  }

  public var actionName: String { "Tempo Change" }

  public func apply(to project: inout Project) throws {
    guard project.tempoMap.tempoChanges.contains(where: { $0.position == oldPosition }) else {
      throw EditError.invalidValue("The tempo change no longer exists.")
    }
    let destination = oldPosition == .zero ? .zero : max(Tick(1), position)
    project.tempoMap.removeTempoChange(at: oldPosition)
    try project.tempoMap.setTempo(bpm, at: destination)
  }
}

/// Removes a tempo change; the first tempo can't be removed.
public struct RemoveTempoChange: EditCommand {
  public var position: Tick

  public init(at position: Tick) {
    self.position = position
  }

  public var actionName: String { "Delete Tempo Change" }

  public func apply(to project: inout Project) throws {
    guard position != .zero else { throw EditError.invalidValue("The first tempo can be changed but not deleted.") }
    project.tempoMap.removeTempoChange(at: position)
  }
}

/// Moves a time signature change to another bar; the first one stays at bar 1.
public struct MoveTimeSignatureChange: EditCommand {
  public var oldBarIndex: Int
  public var barIndex: Int

  public init(fromBarIndex oldBarIndex: Int, toBarIndex barIndex: Int) {
    self.oldBarIndex = oldBarIndex
    self.barIndex = barIndex
  }

  public var actionName: String { "Move Time Signature" }

  public func apply(to project: inout Project) throws {
    guard oldBarIndex != 0 else { throw EditError.invalidValue("The first time signature stays at bar 1.") }
    guard let change = project.tempoMap.meterChanges.first(where: { $0.barIndex == oldBarIndex }) else {
      throw EditError.invalidValue("The time signature change no longer exists.")
    }
    project.tempoMap.removeTimeSignatureChange(atBarIndex: oldBarIndex)
    try project.tempoMap.setTimeSignature(change.signature, atBarIndex: max(1, barIndex))
    project.renderDrummerRegions()
    project.renderPlayerRegions()
  }
}

/// Removes a time signature change; the first one can't be removed.
public struct RemoveTimeSignatureChange: EditCommand {
  public var barIndex: Int

  public init(atBarIndex barIndex: Int) {
    self.barIndex = barIndex
  }

  public var actionName: String { "Delete Time Signature" }

  public func apply(to project: inout Project) throws {
    guard barIndex != 0 else { throw EditError.invalidValue("The first time signature can be changed but not deleted.") }
    project.tempoMap.removeTimeSignatureChange(atBarIndex: barIndex)
    project.renderDrummerRegions()
    project.renderPlayerRegions()
  }
}
