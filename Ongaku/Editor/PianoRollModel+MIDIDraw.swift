//
//  PianoRollModel+MIDIDraw.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// What the MIDI Draw lane shows: each note's velocity, or one kind of controller event.
enum MIDIDrawParameter: Hashable {
  case velocity
  case control(MIDIControlEvent.Kind)
  /// Polyphonic aftertouch of the selected note's pitch.
  case polyPressure

  /// The parameters listed at the top of the lane's menu, as in Logic's MIDI Draw menu.
  static let common: [MIDIDrawParameter] = [
    .velocity, .control(.volume), .control(.pan), .control(.modulation), .control(.expression),
    .control(.sustain), .control(.pitchBend), .control(.channelPressure), .polyPressure,
  ]

  var name: String {
    switch self {
    case .velocity: "Note Velocity"
    case .control(let kind): kind.name
    case .polyPressure: "Poly Aftertouch"
    }
  }

  /// The values the lane spans, bottom to top.
  var valueRange: ClosedRange<Int> {
    switch self {
    case .velocity: MIDINote.velocityRange
    case .control(let kind): kind.valueRange
    case .polyPressure: 0...127
    }
  }

  /// How a value is shown: pan and pitch bend count from the centre.
  func label(for value: Int) -> String {
    switch self {
    case .control(.pan):
      value == 64 ? "C" : value < 64 ? "L\(64 - value)" : "R\(value - 64)"
    case .control(.sustain):
      value >= 64 ? "On (\(value))" : "Off (\(value))"
    case .control(.pitchBend):
      value > 0 ? "+\(value)" : "\(value)"
    default:
      "\(value)"
    }
  }
}

extension PianoRollModel {
  static let midiDrawVisibleKey = "MIDIDrawVisible"
  private static let midiDrawHeightKey = "MIDIDrawHeight"
  static let midiDrawHeightRange: ClosedRange<CGFloat> = 60...320

  static var savedMIDIDrawHeight: CGFloat {
    let saved = UserDefaults.standard.double(forKey: midiDrawHeightKey)
    return saved > 0 ? min(max(CGFloat(saved), midiDrawHeightRange.lowerBound), midiDrawHeightRange.upperBound) : 110
  }

  func saveMIDIDrawHeight() {
    UserDefaults.standard.set(Double(midiDrawHeight), forKey: Self.midiDrawHeightKey)
  }

  /// Controller points being dragged or drawn, before they're committed.
  struct ControlPreview: Equatable {
    /// Points as they'd be after the drag, by identifier (moved and newly drawn ones).
    var events: [MIDIControlEvent]
    /// Points the drag removes from view: a freehand stroke replaces what it passes over.
    var hiddenIDs: Set<MIDIControlEvent.ID> = []
  }

  // MARK: - What the lane edits

  /// The controller kind the lane edits, or `nil` for velocity, and for poly aftertouch
  /// unless exactly one note is selected (it belongs to that note's pitch).
  var drawnKind: MIDIControlEvent.Kind? {
    switch midiDrawParameter {
    case .velocity: return nil
    case .control(let kind): return kind
    case .polyPressure:
      guard selectedNoteIDs.count == 1, let note = notes.first(where: { selectedNoteIDs.contains($0.id) }) else {
        return nil
      }
      return .polyPressure(pitch: note.pitch)
    }
  }

  /// The channel new points go on: the selected note's, or the channel most notes in the
  /// region use, or (with no notes) that of the events already there.
  var drawnChannel: Int {
    if let note = notes.first(where: { selectedNoteIDs.contains($0.id) }) {
      return note.channel
    }
    let counts = Dictionary(grouping: notes.map(\.channel), by: { $0 }).mapValues(\.count)
    if let channel = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key {
      return channel
    }
    if let kind = drawnKind, let event = controls.first(where: { $0.kind == kind }) {
      return event.channel
    }
    return 0
  }

  /// The points the lane shows, with any drag applied, sorted by position.
  var drawnControls: [MIDIControlEvent] {
    guard let kind = drawnKind else { return [] }
    let channel = drawnChannel
    var events = controls.filter { $0.kind == kind && $0.channel == channel }
    if let controlPreview {
      let changed = Dictionary(controlPreview.events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      events = events.filter { !controlPreview.hiddenIDs.contains($0.id) }.map { changed[$0.id] ?? $0 }
      let existing = Set(events.map(\.id))
      events += controlPreview.events.filter { !existing.contains($0.id) }
    }
    return events.sorted { $0.position < $1.position }
  }

  /// The parameters with events in this region, so the menu can mark them.
  var parametersInUse: Set<MIDIDrawParameter> {
    var result: Set<MIDIDrawParameter> = [.velocity]
    for event in controls {
      if case .polyPressure = event.kind {
        result.insert(.polyPressure)
      } else {
        result.insert(.control(event.kind))
      }
    }
    return result
  }

  /// A note's velocity as the lane shows it, during a drag too.
  func displayedVelocity(of note: MIDINote) -> Int {
    velocityPreview?[note.id] ?? note.velocity
  }

  // MARK: - Velocity

  /// Commits the velocities shown while dragging.
  func commitVelocityPreview() {
    guard let region, let preview = velocityPreview else { return }
    velocityPreview = nil
    let changed = notes.compactMap { note -> MIDINote? in
      guard let velocity = preview[note.id], velocity != note.velocity else { return nil }
      var copy = note
      copy.velocity = velocity
      return copy
    }
    guard !changed.isEmpty else { return }
    window.perform(UpdateNotes(changed, in: region.id, actionName: "Change Velocity"))
    if let last = changed.last {
      newNoteVelocity = last.velocity
    }
  }

  // MARK: - Controller points

  func selectControl(_ eventID: MIDIControlEvent.ID, extending: Bool) {
    window.activeEditingArea = .pianoRoll
    if extending {
      if selectedControlIDs.contains(eventID) {
        selectedControlIDs.remove(eventID)
      } else {
        selectedControlIDs.insert(eventID)
      }
    } else if !selectedControlIDs.contains(eventID) {
      selectedControlIDs = [eventID]
    }
  }

  /// Adds a point, as clicking an empty spot of the lane does, and selects it.
  func addControlPoint(at position: Tick, value: Int) {
    guard let region, let kind = drawnKind, position >= .zero else { return }
    let clamped = min(max(value, kind.valueRange.lowerBound), kind.valueRange.upperBound)
    let event = MIDIControlEvent(kind: kind, channel: drawnChannel, position: position, value: clamped)
    window.perform(AddControlEvents([event], to: region.id))
    window.activeEditingArea = .pianoRoll
    selectedControlIDs = [event.id]
  }

  /// Moves points by a time and value offset, keeping them in range.
  func movedControls(_ ids: Set<MIDIControlEvent.ID>, by offset: Tick, valueOffset: Int) -> [MIDIControlEvent] {
    controls.filter { ids.contains($0.id) }.map { event in
      var copy = event
      copy.position = max(.zero, event.position + offset)
      copy.value = min(max(event.value + valueOffset, event.kind.valueRange.lowerBound), event.kind.valueRange.upperBound)
      return copy
    }
  }

  /// Commits the points shown while dragging or drawing.
  func commitControlPreview(drawnOver range: ClosedRange<Tick>? = nil) {
    guard let region, let preview = controlPreview, let kind = drawnKind else {
      controlPreview = nil
      return
    }
    controlPreview = nil
    if let range {
      window.perform(ReplaceControlEvents(kind, channel: drawnChannel, over: range, with: preview.events, in: region.id))
      selectedControlIDs = []
    } else if !preview.events.isEmpty {
      window.perform(UpdateControlEvents(
        preview.events, in: region.id, actionName: preview.events.count == 1 ? "Move Controller Point" : "Move Controller Points"))
    }
  }

  /// Freehand points from a stroke through `samples` (position, value), one every
  /// `spacing` ticks at most and only where the value changes, so a slow stroke doesn't
  /// leave thousands of identical events.
  func strokeEvents(_ samples: [(position: Tick, value: Int)], spacing: Tick = Tick(30)) -> [MIDIControlEvent] {
    guard let kind = drawnKind else { return [] }
    let channel = drawnChannel
    func clamp(_ value: Int) -> Int { min(max(value, kind.valueRange.lowerBound), kind.valueRange.upperBound) }
    let sorted = samples.filter { $0.position >= .zero }.sorted { $0.position < $1.position }
    var events: [MIDIControlEvent] = []
    for sample in sorted {
      let value = clamp(sample.value)
      if let last = events.last {
        guard value != last.value, sample.position - last.position >= spacing else { continue }
      }
      events.append(MIDIControlEvent(kind: kind, channel: channel, position: sample.position, value: value))
    }
    // Always end on the value the stroke ended on, even if it came sooner than `spacing`.
    if let final = sorted.last, let last = events.last, clamp(final.value) != last.value {
      if final.position > last.position {
        events.append(MIDIControlEvent(kind: kind, channel: channel, position: final.position, value: clamp(final.value)))
      } else {
        events[events.count - 1].value = clamp(final.value)
      }
    }
    return events
  }
}
