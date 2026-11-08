//
//  PianoRollModel+StepSequencer.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// What clicking and dragging on steps changes, as Logic's Step Sequencer's edit modes.
enum StepEditMode: String, CaseIterable, Identifiable {
  case on, velocity, gate, chance, repeats

  var id: Self { self }

  var title: String {
    switch self {
    case .on: "Step On/Off"
    case .velocity: "Velocity"
    case .gate: "Gate"
    case .chance: "Chance"
    case .repeats: "Repeats"
    }
  }

  /// A step's value in this mode, 0 to 1 (for drawing it as a bar).
  func fraction(of step: StepPattern.Step) -> Double {
    switch self {
    case .on: step.isOn ? 1 : 0
    case .velocity: Double(step.velocity - 1) / 126
    case .gate: step.gate
    case .chance: step.chance / 100
    case .repeats: Double(step.repeats - 1) / 3
    }
  }

  /// A step with its value set from a fraction (0 to 1), and turned on.
  func applying(_ fraction: Double, to step: StepPattern.Step) -> StepPattern.Step {
    var changed = step
    let fraction = min(max(fraction, 0), 1)
    changed.isOn = true
    switch self {
    case .on: changed.isOn = fraction >= 0.5
    case .velocity: changed.velocity = 1 + Int((fraction * 126).rounded())
    case .gate: changed.gate = max(0.05, (fraction * 20).rounded() / 20)
    case .chance: changed.chance = (fraction * 20).rounded() * 5
    case .repeats: changed.repeats = 1 + Int((fraction * 3).rounded())
    }
    return changed
  }

  /// The value as text, for the cell's help.
  func label(of step: StepPattern.Step) -> String {
    switch self {
    case .on: step.isOn ? "On" : "Off"
    case .velocity: "Velocity \(step.velocity)"
    case .gate: "Gate \(Int(step.gate * 100)) %"
    case .chance: "Chance \(Int(step.chance)) %"
    case .repeats: step.repeats == 1 ? "No repeats" : "\(step.repeats) repeats"
    }
  }
}

extension PianoRollModel {
  var pattern: StepPattern? { region?.pattern }

  /// Changes the open region's pattern as one undoable step.
  func setPattern(_ pattern: StepPattern, actionName: String = "Edit Pattern") {
    guard let region, pattern != region.pattern else { return }
    window.perform(SetStepPattern(pattern, for: region.id, actionName: actionName))
  }

  private func editPattern(_ actionName: String, _ change: (inout StepPattern) -> Void) {
    guard var pattern else { return }
    change(&pattern)
    setPattern(pattern, actionName: actionName)
  }

  // MARK: - Steps

  /// Sets several of a row's steps at once (a click, or a drag across them), each from a
  /// fraction of its value in the edit mode. In Step On/Off, every step becomes what the
  /// first one became.
  func setSteps(_ fractions: [Int: Double], inRow rowID: StepPattern.Row.ID) {
    editPattern("Edit Steps") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      for (step, fraction) in fractions where pattern.rows[index].steps.indices.contains(step) {
        pattern.rows[index].steps[step] = stepEditMode.applying(fraction, to: pattern.rows[index].steps[step])
      }
    }
    if stepEditMode == .on, fractions.values.contains(where: { $0 >= 0.5 }),
      let row = pattern?.rows.first(where: { $0.id == rowID })
    {
      preview(pitch: row.pitch, velocity: 100)
    }
  }

  // MARK: - Rows

  func setRowLength(_ length: Int?, of rowID: StepPattern.Row.ID) {
    editPattern("Row Length") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      pattern.rows[index].length = length
      Self.fit(&pattern.rows[index], to: pattern.length(of: pattern.rows[index]))
    }
  }

  func setRowRate(_ rate: NoteDivision?, of rowID: StepPattern.Row.ID) {
    editPattern("Row Rate") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      pattern.rows[index].rate = rate
    }
  }

  func setRowDirection(_ direction: StepPattern.Row.Direction, of rowID: StepPattern.Row.ID) {
    editPattern("Row Direction") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      pattern.rows[index].direction = direction
    }
  }

  func toggleRowMute(_ rowID: StepPattern.Row.ID) {
    editPattern("Mute Row") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      pattern.rows[index].isMuted.toggle()
    }
  }

  func clearRow(_ rowID: StepPattern.Row.ID) {
    editPattern("Clear Row") { pattern in
      guard let index = pattern.rows.firstIndex(where: { $0.id == rowID }) else { return }
      pattern.rows[index].steps = pattern.rows[index].steps.map { _ in StepPattern.Step() }
    }
  }

  func removeRow(_ rowID: StepPattern.Row.ID) {
    editPattern("Remove Row") { pattern in pattern.rows.removeAll { $0.id == rowID } }
  }

  /// A new row for a note, at the top.
  func addRow(pitch: Int, name: String) {
    editPattern("Add Row") { pattern in
      pattern.rows.insert(
        StepPattern.Row(pitch: pitch, name: name, steps: Array(repeating: StepPattern.Step(), count: pattern.length)), at: 0)
    }
  }

  // MARK: - The pattern

  /// The pattern's length: rows that follow it get steps added (off) or taken away.
  func setPatternLength(_ length: Int) {
    let length = min(max(length, StepPattern.lengthRange.lowerBound), StepPattern.lengthRange.upperBound)
    editPattern("Pattern Length") { pattern in
      pattern.length = length
      for index in pattern.rows.indices where pattern.rows[index].length == nil {
        Self.fit(&pattern.rows[index], to: length)
      }
    }
  }

  func setPatternRate(_ rate: NoteDivision) {
    editPattern("Pattern Rate") { $0.rate = rate }
  }

  func setSwing(_ swing: Double) {
    editPattern("Swing") { $0.swing = min(max(swing, 0), 1) }
  }

  /// Pattern → MIDI Region, to edit the notes in the Piano Roll.
  func convertPatternToNotes() {
    guard let region, region.pattern != nil else { return }
    window.perform(ConvertPatternToNotes([region.id]))
    editorKind = .pianoRoll
  }

  /// Which step each row is on as the song plays (for lighting it), if the playhead is in
  /// the region.
  func currentStep(of row: StepPattern.Row) -> Int? {
    guard let region, let pattern else { return nil }
    let position = window.engine.playheadPosition - region.start
    guard position >= .zero, position < region.length else { return nil }
    let count = Int(position.rawValue / pattern.rate(of: row).ticks.rawValue)
    return pattern.stepIndex(of: row, at: count)
  }

  private static func fit(_ row: inout StepPattern.Row, to length: Int) {
    if row.steps.count < length {
      row.steps += Array(repeating: StepPattern.Step(), count: length - row.steps.count)
    } else if row.steps.count > length {
      row.steps.removeLast(row.steps.count - length)
    }
  }
}

extension ProjectWindowModel {
  /// Whether an instrument track plays drums (a General MIDI kit or the Drum Machine), so a
  /// new pattern starts with a kit's rows.
  func playsDrums(_ track: Track) -> Bool {
    switch track.channel.instrument {
    case .generalMIDIPercussion: return true
    case .sampler(let instrument): return instrument.preset?.isPercussion ?? false
    case .audioUnit(let plugin): return OngakuInstrument(plugin) == .drumMachine
    default: return false
    }
  }

  /// Creates a one-bar pattern region at the bar containing `position` and opens it in the
  /// Step Sequencer: a kit's rows with a beat to start from on drum tracks, an octave of a
  /// scale otherwise.
  func createPatternRegion(on trackID: Track.ID, at position: Tick) {
    guard let track = project.track(withID: trackID), track.kind == .softwareInstrument else { return }
    let tempoMap = project.tempoMap
    let bar = tempoMap.bar(containing: max(.zero, position))
    let end = tempoMap.tickPosition(ofBarIndex: bar.index + 1)
    let pattern = playsDrums(track) ? StepPattern.drums() : StepPattern.notes()
    var region = Region(name: "Pattern", start: bar.start, length: end - bar.start, content: .midi(MIDISequence()), pattern: pattern)
    region.renderPattern()
    perform(AddRegion(region, to: trackID), named: "New Pattern Region")
    selectedTrackID = trackID
    selectedRegionIDs = [region.id]
    openEditor(for: region.id)
    pianoRoll.editorKind = .stepSequencer
  }

  /// Whether Track › New Pattern Region has somewhere to go: the selected track is an
  /// instrument track.
  var canCreatePatternRegionAtPlayhead: Bool {
    selectedTrack?.kind == .softwareInstrument
  }

  /// Track › New Pattern Region: on the selected instrument track, at the bar containing
  /// the playhead.
  func createPatternRegionAtPlayhead() {
    guard let track = selectedTrack, track.kind == .softwareInstrument else { return }
    createPatternRegion(on: track.id, at: engine.playheadPosition)
  }
}
