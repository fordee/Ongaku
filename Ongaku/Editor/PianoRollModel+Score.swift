//
//  PianoRollModel+Score.swift
//  Ongaku
//

import Foundation
import OngakuCore

/// The Score editor's tools, as in Logic's Score editor: select and drag notes, write them
/// with the Pencil at the chosen note value, or erase them.
enum ScoreTool: String, CaseIterable, Identifiable {
  case pointer, pencil, eraser

  var id: Self { self }

  var title: String {
    switch self {
    case .pointer: "Pointer"
    case .pencil: "Pencil"
    case .eraser: "Eraser"
    }
  }

  var symbolName: String {
    switch self {
    case .pointer: "cursorarrow"
    case .pencil: "pencil"
    case .eraser: "eraser"
    }
  }

  var help: String {
    switch self {
    case .pointer: "Click a note to select it (Shift adds to the selection); drag it up or down to change its pitch, or sideways to move it."
    case .pencil: "Click on a staff to write a note of the chosen value there."
    case .eraser: "Click a note to delete it."
    }
  }
}

extension NoteValue.Base {
  /// The Pencil's note values, longest first.
  static let pencilValues: [NoteValue.Base] = [.whole, .half, .quarter, .eighth, .sixteenth]

  var title: String {
    switch self {
    case .whole: "Whole"
    case .half: "Half"
    case .quarter: "Quarter"
    case .eighth: "Eighth"
    case .sixteenth: "Sixteenth"
    case .thirtySecond: "Thirty-Second"
    }
  }
}

extension PianoRollModel {
  /// Whether the open track is drums, written on a drum staff.
  var isScoreDrumPart: Bool { drumLanes != nil }

  /// The open region as notation.
  func scoreLayout(for region: Region) -> ScoreLayout {
    ScoreLayout(region: region, in: window.project, isDrumPart: isScoreDrumPart, options: scoreOptions)
  }

  /// The Pencil: a note of the chosen value at a song position and the pitch written there.
  func writeScoreNote(at position: Tick, pitch: Int) {
    guard let region, position >= region.start, position < region.end else { return }
    let length = Tick(scoreNoteValue.ticks)
    // The stored note is before the region's transpose.
    let note = MIDINote(
      pitch: min(max(pitch - region.transpose, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound),
      velocity: newNoteVelocity, start: position - region.start, length: min(length, region.end - position))
    window.perform(AddNotes([note], to: region.id))
    window.activeEditingArea = .pianoRoll
    selectedNoteIDs = [note.id]
    preview(pitch: pitch, velocity: note.velocity)
  }

  func eraseScoreNote(_ noteID: MIDINote.ID) {
    guard let region else { return }
    window.perform(DeleteNotes([noteID], from: region.id))
    selectedNoteIDs.remove(noteID)
  }

  func selectScoreNote(_ noteID: MIDINote.ID, extending: Bool) {
    window.activeEditingArea = .pianoRoll
    if extending {
      if selectedNoteIDs.contains(noteID) { selectedNoteIDs.remove(noteID) } else { selectedNoteIDs.insert(noteID) }
    } else if !selectedNoteIDs.contains(noteID) {
      selectedNoteIDs = [noteID]
    }
    if let note = notes.first(where: { $0.id == noteID }) {
      preview(pitch: note.pitch + (region?.transpose ?? 0), velocity: note.velocity)
    }
  }

  /// A note dragged in the score: by whole display-quantize steps in time, and by steps of
  /// the key's scale in pitch (a drag up one line or space goes to the next note of the key).
  func moveScoreSelection(by steps: Int, diatonicSteps: Int, key: KeySignature) {
    guard let region, steps != 0 || diatonicSteps != 0 else { return }
    let offset = scoreOptions.quantize * Int64(steps)
    let moved = notes.filter { selectedNoteIDs.contains($0.id) }.map { note in
      var copy = note
      copy.start = max(.zero, note.start + offset)
      if diatonicSteps != 0 {
        let played = note.pitch + region.transpose
        copy.pitch = ScorePitch.move(played, by: diatonicSteps, in: key) - region.transpose
        copy.pitch = min(max(copy.pitch, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound)
      }
      return copy
    }
    window.perform(UpdateNotes(moved, in: region.id, actionName: moved.count == 1 ? "Move Note" : "Move Notes"))
    if let first = moved.first { preview(pitch: first.pitch + region.transpose, velocity: first.velocity) }
  }
}

/// Pitches from staff positions: what a line or space means in a key.
enum ScorePitch {
  /// The note of the key at a diatonic step (one per line and space; see `ScoreNote.diatonic`).
  static func pitch(diatonic: Int, in key: KeySignature) -> Int {
    let naturals = [0, 2, 4, 5, 7, 9, 11]
    let step = ((diatonic % 7) + 7) % 7
    let octave = Int((Double(diatonic) / 7).rounded(.down))
    return (octave + 1) * 12 + naturals[step] + alteration(of: step, in: key)
  }

  /// A drum at a place on the drum staff: the first that's drawn there.
  static func drum(diatonic: Int) -> Int {
    let candidates = [36, 38, 42, 49, 51, 50, 47, 43, 44, 46]
    return candidates.first { pitch in
      let place = DrumNotation.place(pitch)
      return ScoreNote.diatonic(step: place.step, octave: place.octave) == diatonic
    } ?? 38
  }

  /// A pitch moved up or down the key's scale.
  static func move(_ pitch: Int, by steps: Int, in key: KeySignature) -> Int {
    // Find the note's own line or space, then step from there.
    let naturals = [0, 2, 4, 5, 7, 9, 11]
    let pitchClass = ((pitch % 12) + 12) % 12
    let octave = pitch / 12 - 1
    let step = naturals.lastIndex { $0 <= pitchClass } ?? 0
    return Self.pitch(diatonic: octave * 7 + step + steps, in: key)
  }

  static func alteration(of step: Int, in key: KeySignature) -> Int {
    let count = key.sharpsOrFlats
    if count > 0 { return [3, 0, 4, 1, 5, 2, 6].prefix(count).contains(step) ? 1 : 0 }
    if count < 0 { return [6, 2, 5, 1, 4, 0, 3].prefix(-count).contains(step) ? -1 : 0 }
    return 0
  }
}
