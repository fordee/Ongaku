//
//  PianoRollModel+Editing.swift
//  Ongaku
//

import AppKit
import OngakuCore
import OngakuEngine

/// The Piano Roll's tools, as in Logic's (press T, then the tool's key, with the Piano Roll
/// the last place clicked).
enum PianoRollTool: String, CaseIterable, Identifiable {
  case pointer, pencil, brush, eraser, scissors, glue, mute, velocity, quantize

  var id: Self { self }

  var name: String {
    switch self {
    case .pointer: "Pointer Tool"
    case .pencil: "Pencil Tool"
    case .brush: "Brush Tool"
    case .eraser: "Eraser Tool"
    case .scissors: "Scissors Tool"
    case .glue: "Glue Tool"
    case .mute: "Mute Tool"
    case .velocity: "Velocity Tool"
    case .quantize: "Quantize Tool"
    }
  }

  var symbolName: String {
    switch self {
    case .pointer: "cursorarrow"
    case .pencil: "pencil"
    case .brush: "paintbrush.pointed"
    case .eraser: "eraser"
    case .scissors: "scissors"
    case .glue: "drop"
    case .mute: "speaker.slash"
    case .velocity: "slider.vertical.3"
    case .quantize: "squareshape.split.2x2.dotted"
    }
  }

  /// The key that picks it while the Tool menu is open (Logic's).
  var key: Character {
    switch self {
    case .pointer: "t"
    case .pencil: "p"
    case .brush: "b"
    case .eraser: "e"
    case .scissors: "i"
    case .glue: "g"
    case .mute: "m"
    case .velocity: "v"
    case .quantize: "q"
    }
  }

  var help: String {
    switch self {
    case .pointer: "Select, move and resize notes; drag in empty space to select several; Option-drag to copy"
    case .pencil: "Click to add a note, dragging to set its length; drag notes as with the Pointer"
    case .brush: "Drag to paint notes along the grid at the pitch under the pointer"
    case .eraser: "Click a note to delete it (or the selection, if it's selected)"
    case .scissors: "Click a note to split it there"
    case .glue: "Click a selected note to join the selected notes of each pitch"
    case .mute: "Click a note to mute or unmute it"
    case .velocity: "Drag a note up or down to change its velocity (and the selection's)"
    case .quantize: "Click a note to quantize it (or the selection) to the grid"
    }
  }

  /// Whether notes can be moved and resized with the tool.
  var movesNotes: Bool { self == .pointer || self == .pencil }
}

/// Copied notes, shared by every window: their starts are counted from the earliest one.
@MainActor
enum NotePasteboard {
  static var notes: [MIDINote] = []
}

extension PianoRollModel {
  /// The tool a click uses: the chosen one, or the Pencil while Command is held with the
  /// Pointer (Logic's second tool).
  var activeTool: PianoRollTool {
    if tool == .pointer, NSEvent.modifierFlags.contains(.command) { return .pencil }
    return tool
  }

  /// The selection, or every note when nothing is selected (what Logic's functions act on).
  var targetNoteIDs: Set<MIDINote.ID>? {
    selectedNoteIDs.isEmpty ? nil : selectedNoteIDs
  }

  private var selectedNotes: [MIDINote] {
    notes.filter { selectedNoteIDs.contains($0.id) }
  }

  // MARK: - Selecting

  /// The notes worth drawing: those near the visible part of the roll (a margin either way,
  /// so scrolling a little doesn't change them), and any being dragged. A long region can
  /// have thousands of notes, and each is a view with its own gestures.
  var shownNotes: [MIDINote] {
    let range = scroll.renderRange
    let rows = scroll.visibleRows
    let highest = Layout.pitchCount - 1 - rows.lowerBound
    let lowest = Layout.pitchCount - 1 - rows.upperBound
    let isDragging = dragPreview != nil || resizePreview != nil
    return notes.filter { note in
      if isDragging, selectedNoteIDs.contains(note.id) { return true }
      return note.pitch >= lowest && note.pitch <= highest && x(for: note.start) <= range.upperBound
        && x(for: note.end) >= range.lowerBound - Layout.keyboardWidth
    }
  }

  /// The note under a point in the notes area, if any.
  func note(at point: CGPoint) -> MIDINote? {
    let pitch = pitch(forY: point.y)
    let position = position(forX: point.x)
    return notes.last { $0.pitch == pitch && $0.start <= position && $0.end >= position }
  }

  func selectAll() {
    selectedNoteIDs = Set(notes.map(\.id))
    selectedControlIDs = []
  }

  func deselectAll() {
    selectedNoteIDs = []
  }

  func invertSelection() {
    selectedNoteIDs = Set(notes.map(\.id)).subtracting(selectedNoteIDs)
  }

  /// Clicking a key on the keyboard: every note of that pitch, as in Logic.
  func selectAll(pitch: Int, extending: Bool) {
    let matching = Set(notes.filter { $0.pitch == pitch }.map(\.id))
    selectedNoteIDs = extending ? selectedNoteIDs.union(matching) : matching
    window.activeEditingArea = .pianoRoll
  }

  /// Every note of the pitches already selected.
  func selectSamePitches() {
    let pitches = Set(selectedNotes.map(\.pitch))
    selectedNoteIDs = Set(notes.filter { pitches.contains($0.pitch) }.map(\.id))
  }

  func selectMuted() {
    selectedNoteIDs = Set(notes.filter(\.isMuted).map(\.id))
  }

  /// The notes a rubber band touches: over `range` of time, between two pitches.
  func selectNotes(over range: Range<Tick>, pitches: ClosedRange<Int>, extending: Bool) {
    let touched = notes.filter { $0.start < range.upperBound && $0.end > range.lowerBound && pitches.contains($0.pitch) }
    let ids = Set(touched.map(\.id))
    selectedNoteIDs = extending ? selectedNoteIDs.symmetricDifference(ids) : ids
    selectedControlIDs = []
    window.activeEditingArea = .pianoRoll
  }

  // MARK: - Cut, copy, paste and repeat

  var canPasteNotes: Bool { !NotePasteboard.notes.isEmpty && region != nil }

  func copySelection() {
    let copied = selectedNotes
    guard let first = copied.map(\.start).min() else { return }
    NotePasteboard.notes = copied.map { note in
      var copy = note
      copy.start = note.start - first
      return copy
    }
  }

  func cutSelection() {
    guard let region, !selectedNoteIDs.isEmpty else { return }
    copySelection()
    window.perform(DeleteNotes(selectedNoteIDs, from: region.id), named: selectedNoteIDs.count == 1 ? "Cut Note" : "Cut Notes")
    selectedNoteIDs = []
  }

  /// Pastes at the playhead (or the region's start, if the playhead is before it), as
  /// Logic does, and selects what was pasted.
  func paste() {
    guard let region, !NotePasteboard.notes.isEmpty else { return }
    let position = max(.zero, window.engine.playheadPosition - region.start)
    let pasted = NotePasteboard.notes.map { note in
      var copy = note
      copy.id = UUID()
      copy.start = note.start + position
      return copy
    }
    window.perform(AddNotes(pasted, to: region.id), named: pasted.count == 1 ? "Paste Note" : "Paste Notes")
    selectedNoteIDs = Set(pasted.map(\.id))
  }

  /// Copies the selected notes straight after themselves (from the end of the last one,
  /// rounded up to the bar), and selects the copies.
  func repeatSelection() {
    guard let region, let first = selectedNotes.map(\.start).min(), let last = selectedNotes.map(\.end).max() else { return }
    let span = last - first
    // A phrase repeats by whole bars when it fits in them, otherwise by its own length.
    let bar = window.project.tempoMap.timeSignature(atBarIndex: window.project.tempoMap.bar(containing: region.start + first).index)
      .ticksPerBar
    let offset = span <= bar ? bar * Int64((Double(span.rawValue) / Double(bar.rawValue)).rounded(.up)) : span
    copySelection(by: max(offset, grid), pitchOffset: 0, actionName: "Repeat Notes")
  }

  /// Option-dragging: copies of the selected notes, moved, become the selection.
  func copySelection(by offset: Tick, pitchOffset: Int, actionName: String? = nil) {
    guard let region, !selectedNoteIDs.isEmpty else { return }
    let copies = selectedNotes.map { note in
      var copy = note
      copy.id = UUID()
      copy.start = max(.zero, note.start + offset)
      copy.pitch = min(max(note.pitch + pitchOffset, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound)
      return copy
    }
    window.perform(AddNotes(copies, to: region.id), named: actionName ?? (copies.count == 1 ? "Copy Note" : "Copy Notes"))
    selectedNoteIDs = Set(copies.map(\.id))
  }

  // MARK: - Functions

  /// Applies one of Logic's note functions to the selection (or every note).
  func apply(_ function: NoteFunction) {
    guard let region, !notes.isEmpty else { return }
    window.perform(ApplyNoteFunction(function, to: targetNoteIDs, in: region.id))
    // Hear where a transposed note landed.
    if case .transpose = function, let note = notes.first(where: { selectedNoteIDs.contains($0.id) }) {
      preview(pitch: note.pitch, velocity: note.velocity)
    }
  }

  /// Option-Up and Down: transposes the selection a semitone (an octave with Shift).
  func transposeSelection(by semitones: Int) {
    guard !selectedNoteIDs.isEmpty else { return }
    apply(.transpose(semitones))
  }

  /// Option-Left and Right: nudges the selection a grid step.
  func nudgeSelection(by steps: Int) {
    guard !selectedNoteIDs.isEmpty else { return }
    apply(.nudge(grid * Int64(steps)))
  }

  /// Quantizes the selection (or every note) to the grid, with the strength and swing set
  /// in the Quantize menu. With a second grid it's a mixed quantize: each note goes to the
  /// nearer of the two.
  func quantizeSelection(to setting: GridSetting? = nil, or alternative: GridSetting? = nil) {
    guard let region else { return }
    let ticks = setting?.ticks ?? grid
    window.perform(QuantizeNotes(
      in: region.id, noteIDs: targetNoteIDs, grid: ticks, alternativeGrid: alternative?.ticks, strength: quantizeStrength,
      swing: quantizeSwing))
  }

  /// Mutes the selection (or every note, like the other functions), or unmutes it if it's
  /// all muted already.
  func toggleMuteSelection() {
    let targets = selectedNoteIDs.isEmpty ? notes : selectedNotes
    guard !targets.isEmpty else { return }
    apply(.mute(!targets.allSatisfy(\.isMuted)))
  }

  func humanizeSelection() {
    apply(.humanize(timing: Tick(18), velocity: 10, seed: UInt64.random(in: 0...UInt64.max)))
  }

  // MARK: - Tools

  /// What a click on a note does with the current tool. Returns `false` when the tool leaves
  /// it to the usual selecting and dragging (the Pointer and Pencil do).
  func applyTool(to noteID: MIDINote.ID, at localPosition: Tick) -> Bool {
    guard let region else { return false }
    window.activeEditingArea = .pianoRoll
    let targets = selectedNoteIDs.contains(noteID) ? selectedNoteIDs : [noteID]
    switch activeTool {
    case .pointer, .pencil, .brush, .velocity:
      return false
    case .eraser:
      window.perform(DeleteNotes(targets, from: region.id))
      selectedNoteIDs.subtract(targets)
    case .scissors:
      let command = SplitNotes(targets, at: snap(localPosition), in: region.id)
      if window.perform(command) {
        let added = Set(command.newNoteIDs.values).intersection(notes.map(\.id))
        selectedNoteIDs = targets.union(added)
      }
    case .glue:
      guard targets.count > 1 else {
        window.errorMessage = "Select the notes to join, then click one of them with the Glue tool."
        return true
      }
      window.perform(GlueNotes(targets, in: region.id))
      selectedNoteIDs = selectedNoteIDs.intersection(notes.map(\.id))
    case .mute:
      // As with regions: mutes them all, unless the clicked one is muted.
      let mute = notes.first { $0.id == noteID }?.isMuted != true
      window.perform(ApplyNoteFunction(.mute(mute), to: targets, in: region.id))
    case .quantize:
      window.perform(QuantizeNotes(in: region.id, noteIDs: targets, grid: grid, strength: quantizeStrength, swing: quantizeSwing))
    }
    return true
  }

  /// The Pencil dragged from `start` to `end` in empty space: a note at the pitch, from the
  /// grid cell clicked to the grid line nearest the drag's end (at least one step).
  func drawNote(from start: Tick, to end: Tick, pitch: Int) {
    guard let region, start >= .zero else { return }
    let noteStart = snapDown(start)
    let isClick = (end - start).rawValue < grid.rawValue / 2
    let length = isClick ? (lastNoteLength ?? grid) : max(grid, snap(end) - noteStart)
    let note = MIDINote(pitch: pitch, velocity: newNoteVelocity, start: noteStart, length: length)
    window.perform(AddNotes([note], to: region.id))
    window.activeEditingArea = .pianoRoll
    selectedNoteIDs = [note.id]
    lastNoteLength = length
    preview(pitch: pitch, velocity: note.velocity)
  }

  /// The Brush: notes along the grid cells a drag passes, each one step long, at the pitch
  /// under the pointer there (cells that already have a note at that pitch are skipped).
  func paint(_ cells: [(start: Tick, pitch: Int)]) {
    guard let region, !cells.isEmpty else { return }
    var seen = Set<String>()
    let painted = cells.compactMap { cell -> MIDINote? in
      let start = snapDown(cell.start)
      guard start >= .zero, seen.insert("\(start.rawValue).\(cell.pitch)").inserted,
        !notes.contains(where: { $0.pitch == cell.pitch && $0.start == start })
      else { return nil }
      return MIDINote(pitch: cell.pitch, velocity: newNoteVelocity, start: start, length: grid)
    }
    guard !painted.isEmpty else { return }
    window.perform(AddNotes(painted, to: region.id), named: "Paint Notes")
    window.activeEditingArea = .pianoRoll
    selectedNoteIDs = Set(painted.map(\.id))
  }

  /// The Velocity tool: the clicked note (and the selection) louder or softer as it's
  /// dragged up or down, a step a point.
  func velocityChange(for noteID: MIDINote.ID, dragged distance: CGFloat) -> [MIDINote.ID: Int] {
    let targets = selectedNoteIDs.contains(noteID) ? selectedNoteIDs : [noteID]
    let change = Int((-distance / 2).rounded())
    var changed: [MIDINote.ID: Int] = [:]
    for note in notes where targets.contains(note.id) {
      changed[note.id] = min(max(note.velocity + change, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
    }
    return changed
  }

  func finishVelocityChange(_ velocities: [MIDINote.ID: Int]) {
    guard let region, !velocities.isEmpty else { return }
    let changed = notes.compactMap { note -> MIDINote? in
      guard let velocity = velocities[note.id], velocity != note.velocity else { return nil }
      return note.withVelocity(velocity)
    }
    guard !changed.isEmpty else { return }
    window.perform(UpdateNotes(changed, in: region.id, actionName: "Change Velocity"))
  }

  // MARK: - Resizing

  /// Dragging a note's edge resizes every selected note by the same amount, as in Logic:
  /// the end (`fromStart` false) or the start, which keeps the end where it is.
  func resizeSelection(_ noteID: MIDINote.ID, fromStart: Bool, by delta: Tick) {
    guard let region, delta != .zero else { return }
    let targets = selectedNoteIDs.contains(noteID) ? selectedNoteIDs : [noteID]
    let resized = notes.filter { targets.contains($0.id) }.map { note in
      var changed = note
      if fromStart {
        let start = min(max(.zero, note.start + delta), note.end - Tick(1))
        changed.start = start
        changed.length = note.end - start
      } else {
        changed.length = max(Tick(1), note.length + delta)
      }
      return changed
    }
    window.perform(UpdateNotes(resized, in: region.id, actionName: resized.count == 1 ? "Resize Note" : "Resize Notes"))
    if !fromStart, resized.count == 1 { lastNoteLength = resized[0].length }
  }
}

extension MIDINote {
  fileprivate func withVelocity(_ velocity: Int) -> MIDINote {
    var changed = self
    changed.velocity = min(max(velocity, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
    return changed
  }
}
