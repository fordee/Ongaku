//
//  NoteCommands.swift
//  OngakuCore
//

import Foundation

public struct AddNotes: EditCommand {
  public var regionID: Region.ID
  public var notes: [MIDINote]

  public init(_ notes: [MIDINote], to regionID: Region.ID) {
    self.regionID = regionID
    self.notes = notes
  }

  public var actionName: String { notes.count == 1 ? "Add Note" : "Add Notes" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      var noteIDs = Set(sequence.notes.map(\.id))
      for note in notes {
        guard note.isValid else { throw EditError.invalidValue("A note has an invalid pitch, velocity or length.") }
        guard noteIDs.insert(note.id).inserted else { throw EditError.duplicateID(note.id) }
      }
      sequence.notes.append(contentsOf: notes)
    }
  }
}

public struct DeleteNotes: EditCommand {
  public var regionID: Region.ID
  public var noteIDs: Set<MIDINote.ID>

  public init(_ noteIDs: Set<MIDINote.ID>, from regionID: Region.ID) {
    self.regionID = regionID
    self.noteIDs = noteIDs
  }

  public var actionName: String { noteIDs.count == 1 ? "Delete Note" : "Delete Notes" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      sequence.notes.removeAll { noteIDs.contains($0.id) }
    }
  }
}

/// Replaces notes that have matching identifiers (after moving, resizing, transposing,
/// quantizing or changing velocity).
public struct UpdateNotes: EditCommand {
  public var regionID: Region.ID
  public var notes: [MIDINote]
  public var actionName: String

  public init(_ notes: [MIDINote], in regionID: Region.ID, actionName: String = "Edit Notes") {
    self.regionID = regionID
    self.notes = notes
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      for note in notes {
        guard note.isValid else { throw EditError.invalidValue("A note has an invalid pitch, velocity or length.") }
        guard let index = sequence.notes.firstIndex(where: { $0.id == note.id }) else {
          throw EditError.noteNotFound(note.id)
        }
        sequence.notes[index] = note
      }
    }
  }
}

/// Moves note starts to the nearest grid line. Grid lines are measured from each bar line,
/// so odd meters quantize correctly. Lengths are kept. As in Logic, the strength says how
/// far toward the line notes move (1 all the way), and swing delays every second grid line
/// (1 by a third of a step, a triplet feel). A second grid makes it a mixed quantize, like
/// Logic's "1/16 & 1/12": each note goes to whichever grid's line is nearer, so straight
/// and triplet notes in one part both land where they were meant.
public struct QuantizeNotes: EditCommand {
  public var regionID: Region.ID
  /// The notes to quantize; `nil` quantizes every note in the region.
  public var noteIDs: Set<MIDINote.ID>?
  public var grid: Tick
  public var strength: Double
  public var swing: Double
  /// For a mixed quantize: the other grid (a triplet one, say).
  public var alternativeGrid: Tick?

  public init(
    in regionID: Region.ID, noteIDs: Set<MIDINote.ID>? = nil, grid: Tick, alternativeGrid: Tick? = nil, strength: Double = 1,
    swing: Double = 0
  ) {
    self.regionID = regionID
    self.noteIDs = noteIDs
    self.grid = grid
    self.alternativeGrid = alternativeGrid
    self.strength = min(max(strength, 0), 1)
    self.swing = min(max(swing, 0), 1)
  }

  public var actionName: String { "Quantize" }

  public func apply(to project: inout Project) throws {
    guard grid > .zero else { throw EditError.invalidValue("The quantize grid must be longer than zero.") }
    let tempoMap = project.tempoMap
    let regionStart = try project.region(withID: regionID).map(\.start) ?? { throw EditError.regionNotFound(regionID) }()
    try project.editMIDI(in: regionID) { sequence in
      for index in sequence.notes.indices where noteIDs?.contains(sequence.notes[index].id) ?? true {
        let position = regionStart + sequence.notes[index].start
        let barStart = tempoMap.bar(containing: position).start
        let steps = (Double((position - barStart).rawValue) / Double(grid.rawValue)).rounded()
        var target = barStart + grid * Int64(steps)
        if Int64(steps) % 2 != 0 { target += Tick(Int64((Double(grid.rawValue) * swing / 3).rounded())) }
        if let alternativeGrid, alternativeGrid > .zero {
          let other = barStart + alternativeGrid * Int64((Double((position - barStart).rawValue) / Double(alternativeGrid.rawValue)).rounded())
          if abs((other - position).rawValue) < abs((target - position).rawValue) { target = other }
        }
        let moved = Double((target - position).rawValue) * strength
        sequence.notes[index].start = position + Tick(Int64(moved.rounded())) - regionStart
      }
    }
  }
}

// MARK: - Controllers, pitch bend and aftertouch

public struct AddControlEvents: EditCommand {
  public var regionID: Region.ID
  public var events: [MIDIControlEvent]

  public init(_ events: [MIDIControlEvent], to regionID: Region.ID) {
    self.regionID = regionID
    self.events = events
  }

  public var actionName: String { "Add \(events.first?.kind.name ?? "Controller") Point" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      var ids = Set(sequence.controls.map(\.id))
      for event in events {
        guard event.isValid else { throw EditError.invalidValue("A controller event has an invalid value.") }
        guard ids.insert(event.id).inserted else { throw EditError.duplicateID(event.id) }
      }
      sequence.controls.append(contentsOf: events)
    }
  }
}

public struct DeleteControlEvents: EditCommand {
  public var regionID: Region.ID
  public var eventIDs: Set<MIDIControlEvent.ID>

  public init(_ eventIDs: Set<MIDIControlEvent.ID>, from regionID: Region.ID) {
    self.regionID = regionID
    self.eventIDs = eventIDs
  }

  public var actionName: String { eventIDs.count == 1 ? "Delete Controller Point" : "Delete Controller Points" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      sequence.controls.removeAll { eventIDs.contains($0.id) }
    }
  }
}

/// Replaces events that have matching identifiers (after dragging them).
public struct UpdateControlEvents: EditCommand {
  public var regionID: Region.ID
  public var events: [MIDIControlEvent]
  public var actionName: String

  public init(_ events: [MIDIControlEvent], in regionID: Region.ID, actionName: String = "Move Controller Points") {
    self.regionID = regionID
    self.events = events
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      for event in events {
        guard event.isValid else { throw EditError.invalidValue("A controller event has an invalid value.") }
        guard let index = sequence.controls.firstIndex(where: { $0.id == event.id }) else {
          throw EditError.controlEventNotFound(event.id)
        }
        sequence.controls[index] = event
      }
    }
  }
}

/// Replaces the events of one kind and channel within a range with new ones, for drawing a
/// curve freehand over what was there.
public struct ReplaceControlEvents: EditCommand {
  public var regionID: Region.ID
  public var kind: MIDIControlEvent.Kind
  public var channel: Int
  /// Relative to the region start, like the events.
  public var range: ClosedRange<Tick>
  public var events: [MIDIControlEvent]

  public init(
    _ kind: MIDIControlEvent.Kind, channel: Int, over range: ClosedRange<Tick>, with events: [MIDIControlEvent],
    in regionID: Region.ID
  ) {
    self.regionID = regionID
    self.kind = kind
    self.channel = channel
    self.range = range
    self.events = events
  }

  public var actionName: String { "Draw \(kind.name)" }

  public func apply(to project: inout Project) throws {
    guard events.allSatisfy({ $0.kind == kind && $0.channel == channel && $0.isValid }) else {
      throw EditError.invalidValue("Drawn controller events must all be valid and of the kind being drawn.")
    }
    try project.editMIDI(in: regionID) { sequence in
      sequence.controls.removeAll { $0.kind == kind && $0.channel == channel && range.contains($0.position) }
      sequence.controls.append(contentsOf: events)
    }
  }
}

extension Project {
  /// Runs `body` on a MIDI region's notes and controls, and keeps them sorted afterwards.
  mutating func editMIDI(in regionID: Region.ID, _ body: (inout MIDISequence) throws -> Void) throws {
    let location = try requireRegionLocation(regionID)
    guard case .midi(var sequence) = tracks[location.track].regions[location.region].content else {
      throw EditError.trackKindMismatch(expected: .softwareInstrument, found: .audio)
    }
    try body(&sequence)
    sequence.sortNotes()
    tracks[location.track].regions[location.region].content = .midi(sequence)
  }
}
