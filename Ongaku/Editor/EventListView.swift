//
//  EventListView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// Logic's Event List: every note and controller event in the open region, one per line in
/// time order. Click to select (⌘ or ⇧ to add), double-click a channel, number or value to
/// type a new one. The Piano Roll's keys (Delete, Q, ⌥-arrows) act on the selection here too.
struct EventListView: View {
  let model: PianoRollModel
  let region: Region

  static let rowHeight: CGFloat = 20

  var body: some View {
    let events = model.listedEvents
    VStack(spacing: 0) {
      EventListHeaderRow()
      if events.isEmpty {
        Text("No events. Draw notes in the Piano Roll, or controllers in MIDI Draw.")
          .font(Theme.font(11))
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(events) { event in
              EventListRow(model: model, region: region, event: event, isSelected: model.isSelected(event))
            }
          }
        }
      }
    }
    .background(Theme.lanes)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Event List")
    .accessibilityIdentifier("event-list")
  }
}

/// The column widths, shared by the header and the rows.
private enum EventListColumns {
  static let position: CGFloat = 110
  static let status: CGFloat = 86
  static let channel: CGFloat = 36
  static let number: CGFloat = 130
  static let value: CGFloat = 60
  static let length: CGFloat = 90
}

private struct EventListHeaderRow: View {
  var body: some View {
    HStack(spacing: 0) {
      cell("Position", EventListColumns.position)
      cell("Status", EventListColumns.status)
      cell("Ch", EventListColumns.channel)
      cell("Num", EventListColumns.number)
      cell("Val", EventListColumns.value)
      cell("Length", EventListColumns.length)
      Spacer(minLength: 0)
    }
    .frame(height: 22)
    .background(Theme.panel)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }

  private func cell(_ title: String, _ width: CGFloat) -> some View {
    Text(title)
      .font(Theme.font(10, weight: .semibold))
      .foregroundStyle(Theme.secondaryText)
      .frame(width: width, alignment: .leading)
      .padding(.leading, 8)
  }
}

private struct EventListRow: View, Equatable {
  let model: PianoRollModel
  let region: Region
  let event: PianoRollModel.ListedEvent
  let isSelected: Bool

  @State private var editing: PianoRollModel.EventListColumn?
  @State private var text = ""
  @FocusState private var isFieldFocused: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.event == rhs.event && lhs.isSelected == rhs.isSelected && lhs.region.start == rhs.region.start
  }

  var body: some View {
    let tempoMap = model.window.project.tempoMap
    HStack(spacing: 0) {
      label(tempoMap.musicalPosition(at: region.start + event.position).description, EventListColumns.position)
      label(event.status, EventListColumns.status, color: Theme.secondaryText)
      editable(.channel, "\(event.channel + 1)", EventListColumns.channel)
      editable(.number, event.number, EventListColumns.number)
      editable(.value, "\(event.value)", EventListColumns.value)
      label(event.length.map(Self.lengthText) ?? "", EventListColumns.length)
      Spacer(minLength: 0)
    }
    .frame(height: EventListView.rowHeight)
    .background(isSelected ? Theme.headerSelected : Color.clear)
    .contentShape(.rect)
    .onTapGesture {
      let modifiers = NSEvent.modifierFlags
      model.window.activeEditingArea = .pianoRoll
      model.selectEvent(event, extending: modifiers.contains(.command) || modifiers.contains(.shift))
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("event-row")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func label(_ text: String, _ width: CGFloat, color: Color = Theme.text) -> some View {
    Text(text)
      .font(Theme.monospaced(11, weight: .regular))
      .foregroundStyle(color)
      .lineLimit(1)
      .frame(width: width, alignment: .leading)
      .padding(.leading, 8)
  }

  @ViewBuilder
  private func editable(_ column: PianoRollModel.EventListColumn, _ value: String, _ width: CGFloat) -> some View {
    if editing == column {
      TextField("", text: $text)
        .textFieldStyle(.plain)
        .font(Theme.monospaced(11, weight: .regular))
        .foregroundStyle(Theme.text)
        .focused($isFieldFocused)
        .onSubmit { commit(column) }
        .onExitCommand { editing = nil }
        .onChange(of: isFieldFocused) { _, isFocused in
          if !isFocused { editing = nil }
        }
        .frame(width: width - 4, alignment: .leading)
        .padding(.leading, 8)
        .background(Theme.raised)
    } else {
      label(value, width)
        .onTapGesture(count: 2) {
          text = column == .number ? event.number.components(separatedBy: " ").first ?? "" : value
          editing = column
          isFieldFocused = true
        }
    }
  }

  private func commit(_ column: PianoRollModel.EventListColumn) {
    editing = nil
    if !model.setEvent(event, column, to: text) { NSSound.beep() }
  }

  /// A note's length in beats, sixteenths and ticks, as Logic's Length column shows it.
  static func lengthText(_ length: Tick) -> String {
    let perBeat = Tick.perQuarterNote, perDivision = perBeat / 4
    let raw = length.rawValue
    return "\(raw / perBeat) \((raw % perBeat) / perDivision) \(raw % perDivision)"
  }
}

#Preview {
  EventListPreview()
    .frame(width: 760, height: 360)
}

/// Keeps the window model alive: the editor's model refers to it without owning it.
private struct EventListPreview: View {
  @State private var window: ProjectWindowModel = {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let chord = [60, 64, 67].map { MIDINote(pitch: $0, velocity: 96, start: .zero, length: .quarterNotes(2)) }
    let melody = [72, 74, 76].enumerated().map { index, pitch in
      MIDINote(pitch: pitch, velocity: 80 + index * 10, start: .quarterNotes(2 + Double(index) * 0.5), length: .quarterNotes(0.5))
    }
    let controls = [
      MIDIControlEvent(kind: .sustain, position: .zero, value: 127),
      MIDIControlEvent(kind: .modulation, position: .quarterNotes(1), value: 64),
      MIDIControlEvent(kind: .pitchBend, position: .quarterNotes(3), value: 2048),
      MIDIControlEvent(kind: .sustain, position: .quarterNotes(3.5), value: 0),
    ]
    let region = Region(
      name: "Chords", start: .quarterNotes(4), length: .quarterNotes(4), content: .midi(MIDISequence(notes: chord + melody, controls: controls)))
    keys.regions = [region]
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
    window.editorRegionID = region.id
    window.pianoRoll.editorKind = .eventList
    window.pianoRoll.selectedNoteIDs = [melody[1].id]
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
