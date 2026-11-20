//
//  PianoRollModel+EventList.swift
//  Ongaku
//

import Foundation
import OngakuCore

/// Logic's Event List: the open region's notes, controllers, pitch bend and aftertouch as
/// one list in time order, with their numbers to read and type over.
extension PianoRollModel {
  /// One line of the list.
  enum ListedEvent: Identifiable, Equatable {
    case note(MIDINote)
    case control(MIDIControlEvent)

    var id: UUID {
      switch self {
      case .note(let note): note.id
      case .control(let event): event.id
      }
    }

    /// From the region's start.
    var position: Tick {
      switch self {
      case .note(let note): note.start
      case .control(let event): event.position
      }
    }

    /// What kind of message, as Logic's Status column says it.
    var status: String {
      switch self {
      case .note: "Note"
      case .control(let event):
        switch event.kind {
        case .controller: "Control"
        case .pitchBend: "Pitch Bend"
        case .channelPressure: "Aftertouch"
        case .polyPressure: "Poly AT"
        }
      }
    }

    var channel: Int {
      switch self {
      case .note(let note): note.channel
      case .control(let event): event.channel
      }
    }

    /// The note's name, the controller's number and name, or the key poly aftertouch acts on.
    var number: String {
      switch self {
      case .note(let note): PianoRollModel.noteName(note.pitch)
      case .control(let event):
        switch event.kind {
        case .controller(let number):
          MIDIControlEvent.Kind.controllerNames[number].map { "\(number) \($0)" } ?? "\(number)"
        case .polyPressure(let pitch): PianoRollModel.noteName(pitch)
        case .pitchBend, .channelPressure: ""
        }
      }
    }

    /// Velocity for a note, otherwise the event's value.
    var value: Int {
      switch self {
      case .note(let note): note.velocity
      case .control(let event): event.value
      }
    }

    var length: Tick? {
      if case .note(let note) = self { note.length } else { nil }
    }
  }

  /// A column that can be typed over.
  enum EventListColumn {
    case channel, number, value
  }

  /// Every event in the region, in time order (a note before a controller at the same time).
  var listedEvents: [ListedEvent] {
    let events = notes.map(ListedEvent.note) + controls.map(ListedEvent.control)
    return events.enumerated().sorted { lhs, rhs in
      lhs.element.position != rhs.element.position ? lhs.element.position < rhs.element.position : lhs.offset < rhs.offset
    }.map(\.element)
  }

  func isSelected(_ event: ListedEvent) -> Bool {
    switch event {
    case .note(let note): selectedNoteIDs.contains(note.id)
    case .control(let control): selectedControlIDs.contains(control.id)
    }
  }

  /// Selects a line, as clicking it does (adding it to the selection, or taking it out,
  /// with `extending`).
  func selectEvent(_ event: ListedEvent, extending: Bool) {
    if !extending {
      selectedNoteIDs = []
      selectedControlIDs = []
    }
    switch event {
    case .note(let note):
      if extending, selectedNoteIDs.contains(note.id) { selectedNoteIDs.remove(note.id) } else { selectedNoteIDs.insert(note.id) }
    case .control(let control):
      if extending, selectedControlIDs.contains(control.id) {
        selectedControlIDs.remove(control.id)
      } else {
        selectedControlIDs.insert(control.id)
      }
    }
  }

  /// Types a new value into a column. Returns false if the text isn't one (the line is left
  /// as it was): a channel 1–16, a note name such as "D♯3" or a MIDI number, or a value in
  /// the event's range.
  @discardableResult
  func setEvent(_ event: ListedEvent, _ column: EventListColumn, to text: String) -> Bool {
    guard let regionID = region?.id else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    switch event {
    case .note(var note):
      switch column {
      case .channel:
        guard let channel = Int(trimmed), (1...16).contains(channel) else { return false }
        note.channel = channel - 1
      case .number:
        guard let pitch = Self.pitch(named: trimmed), MIDINote.pitchRange.contains(pitch) else { return false }
        note.pitch = pitch
      case .value:
        guard let velocity = Int(trimmed), MIDINote.velocityRange.contains(velocity) else { return false }
        note.velocity = velocity
      }
      return window.perform(UpdateNotes([note], in: regionID, actionName: "Edit Note"))
    case .control(var control):
      switch column {
      case .channel:
        guard let channel = Int(trimmed), (1...16).contains(channel) else { return false }
        control.channel = channel - 1
      case .number:
        // Which controller an event is stays as it was: draw a new one to change it.
        return false
      case .value:
        guard let value = Int(trimmed), control.kind.valueRange.contains(value) else { return false }
        control.value = value
      }
      return window.perform(UpdateControlEvents([control], in: regionID, actionName: "Edit Event"))
    }
  }

  /// A pitch from a number or a name as `noteName` writes it ("C3" is 60; "C#3", "C♯3" and
  /// "Db3" all work).
  static func pitch(named text: String) -> Int? {
    if let number = Int(text) { return number }
    let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    var rest = Substring(text)
    guard let letter = rest.first?.uppercased().first, let pitchClass = letters[letter] else { return nil }
    rest = rest.dropFirst()
    var accidental = 0
    while let next = rest.first, "#♯b♭".contains(next) {
      accidental += next == "#" || next == "♯" ? 1 : -1
      rest = rest.dropFirst()
    }
    guard let octave = Int(rest) else { return nil }
    return (octave + 2) * 12 + pitchClass + accidental
  }
}
