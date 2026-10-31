//
//  PianoRollModel+StepEditor.swift
//  Ongaku
//

import Foundation
import OngakuCore

/// One row of the Step Editor: a note (each drum of a kit, say) or a controller. Its events
/// are bars on the step grid, as tall as their velocity or value.
enum StepLane: Hashable, Identifiable {
  case note(pitch: Int)
  case control(MIDIControlEvent.Kind)

  var id: Self { self }

  /// The values a bar can have: velocity for notes, the controller's range otherwise.
  var valueRange: ClosedRange<Int> {
    switch self {
    case .note: MIDINote.velocityRange
    case .control(let kind): kind.valueRange
    }
  }
}

extension PianoRollModel {
  /// Which editor the pane shows, like the tabs over Logic's editors.
  enum EditorKind: String, CaseIterable, Identifiable {
    case pianoRoll, stepEditor, stepSequencer, drummer, player, takes, pitch

    var id: Self { self }

    var title: String {
      switch self {
      case .pianoRoll: "Piano Roll"
      case .stepEditor: "Step Editor"
      case .stepSequencer: "Step Sequencer"
      case .drummer: "Drummer"
      case .player: "Player"
      case .takes: "Takes"
      case .pitch: "Flex Pitch"
      }
    }
  }

  /// The editors that suit the open region: the MIDI editors for MIDI, Takes for a take
  /// folder, first (an audio take folder only has Takes; in a MIDI one the MIDI editors edit
  /// the take that starts the comp).
  var availableEditors: [EditorKind] {
    guard let region else { return [.pianoRoll, .stepEditor] }
    // A pattern region is edited in the Step Sequencer (convert it to edit its notes).
    if region.pattern != nil { return [.stepSequencer] }
    // So is a drummer region in the Drummer editor.
    if region.drummer != nil { return [.drummer] }
    // And a session player region in the Player editor.
    if region.player != nil { return [.player] }
    let isMIDI = if case .midi = region.content { true } else { false }
    let isFlexPitch = !isMIDI && track?.flexMode == .pitch && region.takeFolder == nil
    return (region.takeFolder != nil ? [.takes] : []) + (isMIDI ? [.pianoRoll, .stepEditor] : []) + (isFlexPitch ? [.pitch] : [])
  }

  /// In a MIDI take folder, the take the Piano Roll and Step Editor change: the one that
  /// starts the comp (the region's own notes).
  var editedTake: Take? {
    guard let region, let folder = region.takeFolder, let lead = region.leadTakeID else { return nil }
    return folder.take(withID: lead)
  }

  /// The editor shown: the chosen one if it suits the region, otherwise the first that does.
  var shownEditor: EditorKind {
    let available = availableEditors
    return available.contains(editorKind) ? editorKind : available.first ?? .pianoRoll
  }

  /// The General MIDI drums Logic's Step Editor lists for a drum kit, top to bottom.
  static let generalMIDIDrumLanes: [(pitch: Int, name: String)] = [
    (49, "Crash"), (51, "Ride"), (46, "Open Hi-Hat"), (42, "Closed Hi-Hat"), (50, "High Tom"), (47, "Mid Tom"),
    (45, "Low Tom"), (39, "Clap"), (38, "Snare"), (37, "Side Stick"), (36, "Kick"),
  ]

  /// The Drum Machine's pads, in the same order, with its own names (it has no ride, and
  /// adds a cowbell and shaker). They match its pads in OngakuEffects' Parameters.swift.
  static let drumMachineLanes: [(pitch: Int, name: String)] = [
    (49, "Crash"), (46, "Open Hat"), (42, "Closed Hat"), (50, "High Tom"), (47, "Mid Tom"), (45, "Low Tom"),
    (70, "Shaker"), (56, "Cowbell"), (39, "Clap"), (38, "Snare"), (37, "Rim"), (36, "Kick"),
  ]

  /// The drums listed for the track's kit, if it plays drums (the same test the Step
  /// Sequencer uses for a new pattern's rows).
  var drumLanes: [(pitch: Int, name: String)]? {
    guard let track, window.playsDrums(track) else { return nil }
    return window.drummerKit(for: track) == .drumMachine ? Self.drumMachineLanes : Self.generalMIDIDrumLanes
  }

  /// The Step Editor's lanes: for a drum kit, its drums; otherwise every pitch the region
  /// uses, highest first; then modulation, sustain and any other controllers in use.
  var stepLanes: [StepLane] {
    let usedPitches = Set(notes.map(\.pitch))
    var lanes: [StepLane]
    if let drumLanes {
      let drums = drumLanes.map(\.pitch)
      lanes = drums.map { StepLane.note(pitch: $0) }
        + usedPitches.subtracting(drums).sorted(by: >).map { StepLane.note(pitch: $0) }
    } else {
      lanes = usedPitches.sorted(by: >).map { StepLane.note(pitch: $0) }
      if lanes.isEmpty {
        lanes = [.note(pitch: 60)]
      }
    }
    var controls: [MIDIControlEvent.Kind] = [.modulation, .sustain]
    for event in self.controls where !controls.contains(event.kind) {
      controls.append(event.kind)
    }
    return lanes + controls.map(StepLane.control)
  }

  /// A lane's name: the drum or note name, or the controller's.
  func name(of lane: StepLane) -> String {
    switch lane {
    case .note(let pitch):
      if let drum = drumLanes?.first(where: { $0.pitch == pitch }) {
        return drum.name
      }
      return Self.noteName(pitch)
    case .control(let kind):
      return kind.name
    }
  }

  /// The step grid: the grid setting, or sixteenths when it's automatic.
  var stepLength: Tick {
    gridSetting.ticks ?? Tick(240)
  }

  /// How many steps the region holds.
  var stepCount: Int {
    guard let region else { return 0 }
    return Int((region.length.rawValue + stepLength.rawValue - 1) / stepLength.rawValue)
  }

  /// The step a position (relative to the region) falls in.
  func step(at localPosition: Tick) -> Int {
    Int(localPosition.rawValue / stepLength.rawValue)
  }

  /// Every lane's values by step (the first event on a step, if there are several), in one
  /// pass over the region's events: what the Step Editor draws.
  func stepValues() -> [StepLane: [Int: Int]] {
    let length = stepLength.rawValue
    var values: [StepLane: [Int: Int]] = [:]
    for note in notes where note.start >= .zero {
      let step = Int(note.start.rawValue / length)
      if values[.note(pitch: note.pitch)]?[step] == nil { values[.note(pitch: note.pitch), default: [:]][step] = note.velocity }
    }
    for event in controls where event.position >= .zero {
      let step = Int(event.position.rawValue / length)
      if values[.control(event.kind)]?[step] == nil { values[.control(event.kind), default: [:]][step] = event.value }
    }
    return values
  }

  /// The value of a lane's event on a step (the first one, if there are several), if any.
  func stepValue(_ lane: StepLane, at step: Int) -> Int? {
    let range = stepRange(step)
    switch lane {
    case .note(let pitch):
      return notes.first { $0.pitch == pitch && range.contains($0.start) }?.velocity
    case .control(let kind):
      return controls.first { $0.kind == kind && range.contains($0.position) }?.value
    }
  }

  private func stepRange(_ step: Int) -> Range<Tick> {
    let start = stepLength * Int64(step)
    return start..<(start + stepLength)
  }

  /// Sets lanes' values on steps, adding events where there are none, in one undo step: a
  /// click or a drag across a lane in the Step Editor.
  func setStepValues(_ values: [Int: Int], in lane: StepLane) {
    guard let region, !values.isEmpty else { return }
    var added: [MIDINote] = []
    var updated: [MIDINote] = []
    var addedControls: [MIDIControlEvent] = []
    var updatedControls: [MIDIControlEvent] = []
    for (step, rawValue) in values where step >= 0 && step < stepCount {
      let value = min(max(rawValue, lane.valueRange.lowerBound), lane.valueRange.upperBound)
      let range = stepRange(step)
      switch lane {
      case .note(let pitch):
        if var note = notes.first(where: { $0.pitch == pitch && range.contains($0.start) }) {
          note.velocity = value
          updated.append(note)
        } else {
          // A new step plays for the step's length (a drum hit doesn't need more).
          added.append(MIDINote(pitch: pitch, velocity: value, start: range.lowerBound, length: stepLength))
        }
      case .control(let kind):
        if var event = controls.first(where: { $0.kind == kind && range.contains($0.position) }) {
          event.value = value
          updatedControls.append(event)
        } else {
          addedControls.append(MIDIControlEvent(kind: kind, position: range.lowerBound, value: value))
        }
      }
    }
    var commands: [any EditCommand] = []
    if !added.isEmpty { commands.append(AddNotes(added, to: region.id)) }
    if !updated.isEmpty { commands.append(UpdateNotes(updated, in: region.id, actionName: "Step Edit")) }
    if !addedControls.isEmpty { commands.append(AddControlEvents(addedControls, to: region.id)) }
    if !updatedControls.isEmpty { commands.append(UpdateControlEvents(updatedControls, in: region.id, actionName: "Step Edit")) }
    guard !commands.isEmpty else { return }
    window.perform(CompositeCommand("Step Edit", commands: commands))
  }

  /// Removes a lane's events on a step (double-clicking a bar).
  func clearStep(_ lane: StepLane, at step: Int) {
    guard let region else { return }
    let range = stepRange(step)
    switch lane {
    case .note(let pitch):
      let ids = Set(notes.filter { $0.pitch == pitch && range.contains($0.start) }.map(\.id))
      if !ids.isEmpty { window.perform(DeleteNotes(ids, from: region.id)) }
    case .control(let kind):
      let ids = Set(controls.filter { $0.kind == kind && range.contains($0.position) }.map(\.id))
      if !ids.isEmpty { window.perform(DeleteControlEvents(ids, from: region.id)) }
    }
  }
}
