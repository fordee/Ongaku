//
//  NoteFunctions.swift
//  OngakuCore
//

import Foundation

/// The note functions of Logic's Piano Roll (its Functions menu), applied to some of a
/// region's notes. Each works only on the notes it's given; positions are relative to the
/// region start, like the notes.
public enum NoteFunction: Sendable, Equatable {
  /// Up or down by semitones (notes that would leave the MIDI range stay where they are).
  case transpose(Int)
  /// Earlier or later (never before the region start).
  case nudge(Tick)
  /// Force Legato: each note lasts until the next one starts.
  case legato
  /// Shortens notes that run into the next note of the same pitch.
  case removeOverlaps
  case setLength(Tick)
  case setVelocity(Int)
  /// Scales velocities by a factor (1.2 is 20 % louder).
  case scaleVelocity(Double)
  case addVelocity(Int)
  /// Moves notes and changes their velocities by up to these amounts at random, so a
  /// programmed part sounds played. The seed makes it the same each time it's applied.
  case humanize(timing: Tick, velocity: Int, seed: UInt64)
  /// Plays the notes backwards in time, within the span they cover.
  case reverse
  /// Mirrors the pitches: the highest becomes the lowest.
  case invert
  case mute(Bool)

  public var actionName: String {
    switch self {
    case .transpose(let semitones): semitones > 0 ? "Transpose Up" : "Transpose Down"
    case .nudge(let offset): offset > .zero ? "Nudge Right" : "Nudge Left"
    case .legato: "Force Legato"
    case .removeOverlaps: "Remove Overlaps"
    case .setLength: "Set Note Length"
    case .setVelocity, .scaleVelocity, .addVelocity: "Change Velocity"
    case .humanize: "Humanize"
    case .reverse: "Reverse"
    case .invert: "Invert"
    case .mute(let isMuted): isMuted ? "Mute Notes" : "Unmute Notes"
    }
  }

  /// The notes, changed.
  public func apply(to notes: [MIDINote]) -> [MIDINote] {
    switch self {
    case .transpose(let semitones):
      return notes.map { note in
        var changed = note
        let pitch = note.pitch + semitones
        if MIDINote.pitchRange.contains(pitch) { changed.pitch = pitch }
        return changed
      }
    case .nudge(let offset):
      return notes.map { note in
        var changed = note
        changed.start = max(.zero, note.start + offset)
        return changed
      }
    case .legato:
      let starts = Set(notes.map(\.start)).sorted()
      return notes.map { note in
        var changed = note
        if let next = starts.first(where: { $0 > note.start }) { changed.length = next - note.start }
        return changed
      }
    case .removeOverlaps:
      var changed = notes
      let groups = Dictionary(grouping: notes.indices) { PitchKey(pitch: notes[$0].pitch, channel: notes[$0].channel) }
      for indices in groups.values {
        let sorted = indices.sorted { notes[$0].start < notes[$1].start }
        for (current, next) in zip(sorted, sorted.dropFirst()) where changed[current].end > notes[next].start {
          changed[current].length = max(Tick(1), notes[next].start - notes[current].start)
        }
      }
      return changed
    case .setLength(let length):
      return notes.map { note in
        var changed = note
        changed.length = max(Tick(1), length)
        return changed
      }
    case .setVelocity(let velocity):
      return notes.map { $0.withVelocity(velocity) }
    case .scaleVelocity(let factor):
      return notes.map { $0.withVelocity(Int((Double($0.velocity) * factor).rounded())) }
    case .addVelocity(let amount):
      return notes.map { $0.withVelocity($0.velocity + amount) }
    case .humanize(let timing, let velocity, let seed):
      var random = SplitMix(seed: seed)
      return notes.map { note in
        var changed = note
        if timing > .zero {
          let shift = Int64((random.unit() * 2 - 1) * Double(timing.rawValue))
          changed.start = max(.zero, note.start + Tick(shift))
        }
        if velocity > 0 {
          changed = changed.withVelocity(note.velocity + Int(((random.unit() * 2 - 1) * Double(velocity)).rounded()))
        }
        return changed
      }
    case .reverse:
      guard let first = notes.map(\.start).min(), let last = notes.map(\.end).max() else { return notes }
      return notes.map { note in
        var changed = note
        changed.start = first + (last - note.end)
        return changed
      }
    case .invert:
      guard let low = notes.map(\.pitch).min(), let high = notes.map(\.pitch).max() else { return notes }
      return notes.map { note in
        var changed = note
        changed.pitch = low + high - note.pitch
        return changed
      }
    case .mute(let isMuted):
      return notes.map { note in
        var changed = note
        changed.isMuted = isMuted
        return changed
      }
    }
  }

  private struct PitchKey: Hashable {
    var pitch: Int
    var channel: Int
  }
}

extension MIDINote {
  func withVelocity(_ velocity: Int) -> MIDINote {
    var changed = self
    changed.velocity = min(max(velocity, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
    return changed
  }
}

/// A small, seeded random number generator (SplitMix64), so humanizing gives the same
/// result when it's redone.
struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// 0 up to (not including) 1.
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Applies a note function to some of a region's notes (all of them when `noteIDs` is nil).
public struct ApplyNoteFunction: EditCommand {
  public var regionID: Region.ID
  public var noteIDs: Set<MIDINote.ID>?
  public var function: NoteFunction

  public init(_ function: NoteFunction, to noteIDs: Set<MIDINote.ID>?, in regionID: Region.ID) {
    self.regionID = regionID
    self.noteIDs = noteIDs
    self.function = function
  }

  public var actionName: String { function.actionName }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      let indices = sequence.notes.indices.filter { noteIDs?.contains(sequence.notes[$0].id) ?? true }
      let changed = function.apply(to: indices.map { sequence.notes[$0] })
      for (index, note) in zip(indices, changed) {
        guard note.isValid else { throw EditError.invalidValue("A note has an invalid pitch, velocity or length.") }
        sequence.notes[index] = note
      }
    }
  }
}

/// The Scissors: splits each note that spans a position into two, the second starting
/// there. The second halves get the identifiers in `newNoteIDs`, so they can be selected.
public struct SplitNotes: EditCommand {
  public var regionID: Region.ID
  public var noteIDs: Set<MIDINote.ID>
  public var position: Tick
  /// The identifier each split note's second half gets.
  public var newNoteIDs: [MIDINote.ID: MIDINote.ID]

  public init(_ noteIDs: Set<MIDINote.ID>, at position: Tick, in regionID: Region.ID) {
    self.regionID = regionID
    self.noteIDs = noteIDs
    self.position = position
    newNoteIDs = Dictionary(uniqueKeysWithValues: noteIDs.map { ($0, UUID()) })
  }

  public var actionName: String { noteIDs.count == 1 ? "Split Note" : "Split Notes" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      var added: [MIDINote] = []
      for index in sequence.notes.indices {
        let note = sequence.notes[index]
        guard noteIDs.contains(note.id), note.start < position, note.end > position, let newID = newNoteIDs[note.id] else {
          continue
        }
        var second = note
        second.id = newID
        second.start = position
        second.length = note.end - position
        sequence.notes[index].length = position - note.start
        added.append(second)
      }
      sequence.notes.append(contentsOf: added)
    }
  }
}

/// The Glue tool: joins the given notes of each pitch (and channel) into one note, from the
/// first one's start to the last one's end, at the first one's velocity.
public struct GlueNotes: EditCommand {
  public var regionID: Region.ID
  public var noteIDs: Set<MIDINote.ID>

  public init(_ noteIDs: Set<MIDINote.ID>, in regionID: Region.ID) {
    self.regionID = regionID
    self.noteIDs = noteIDs
  }

  public var actionName: String { "Glue Notes" }

  public func apply(to project: inout Project) throws {
    try project.editMIDI(in: regionID) { sequence in
      let chosen = sequence.notes.filter { noteIDs.contains($0.id) }
      let groups = Dictionary(grouping: chosen) { "\($0.pitch).\($0.channel)" }
      var removed: Set<MIDINote.ID> = []
      for group in groups.values where group.count > 1 {
        let sorted = group.sorted { $0.start < $1.start }
        guard let first = sorted.first, let end = sorted.map(\.end).max(),
          let index = sequence.notes.firstIndex(where: { $0.id == first.id })
        else { continue }
        sequence.notes[index].length = end - first.start
        removed.formUnion(sorted.dropFirst().map(\.id))
      }
      sequence.notes.removeAll { removed.contains($0.id) }
    }
  }
}
