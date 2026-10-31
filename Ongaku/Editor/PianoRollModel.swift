//
//  PianoRollModel.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// State and editing actions for the piano roll, which edits the MIDI region open in the
/// window's editor. Positions here are relative to the region start, like the notes.
@MainActor
@Observable
final class PianoRollModel {
  enum Layout {
    static let keyboardWidth: CGFloat = 64
    static let rulerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 12
    static let pitchCount = 128
    static var contentHeight: CGFloat { CGFloat(pitchCount) * rowHeight }
  }

  /// The grid notes snap and quantize to.
  enum GridSetting: String, CaseIterable, Identifiable {
    case automatic, quarter, eighth, sixteenth, thirtySecond
    case quarterTriplet, eighthTriplet, sixteenthTriplet, thirtySecondTriplet

    var id: Self { self }

    static let straight: [GridSetting] = [.quarter, .eighth, .sixteenth, .thirtySecond]
    static let triplets: [GridSetting] = [.quarterTriplet, .eighthTriplet, .sixteenthTriplet, .thirtySecondTriplet]

    var title: String {
      switch self {
      case .automatic: "Auto"
      case .quarter: "1/4"
      case .eighth: "1/8"
      case .sixteenth: "1/16"
      case .thirtySecond: "1/32"
      case .quarterTriplet: "1/4T"
      case .eighthTriplet: "1/8T"
      case .sixteenthTriplet: "1/16T"
      case .thirtySecondTriplet: "1/32T"
      }
    }

    /// Logic's name: the fraction of a 4/4 bar (twelve 1/8 triplets fill one, so "1/12").
    var logicName: String {
      switch self {
      case .quarterTriplet: "1/6"
      case .eighthTriplet: "1/12"
      case .sixteenthTriplet: "1/24"
      case .thirtySecondTriplet: "1/48"
      default: title
      }
    }

    /// The name in the Quantize menu.
    var quantizeTitle: String {
      switch self {
      case .quarterTriplet, .eighthTriplet, .sixteenthTriplet, .thirtySecondTriplet:
        "\(title.dropLast()) Triplet (\(logicName))"
      default: "\(title) Note"
      }
    }

    /// Three triplets take the time of two straight notes: 960 ticks a quarter makes them exact.
    var ticks: Tick? {
      switch self {
      case .automatic: nil
      case .quarter: Tick(960)
      case .eighth: Tick(480)
      case .sixteenth: Tick(240)
      case .thirtySecond: Tick(120)
      case .quarterTriplet: Tick(640)
      case .eighthTriplet: Tick(320)
      case .sixteenthTriplet: Tick(160)
      case .thirtySecondTriplet: Tick(80)
      }
    }
  }

  /// Logic's mixed quantize: each note goes to the nearer of a straight and a triplet grid,
  /// so a part with both straight and triplet notes tidies without losing either.
  struct MixedQuantize: Identifiable {
    let straight: GridSetting
    let triplet: GridSetting

    var id: String { title }
    var title: String { "\(straight.title) & \(triplet.logicName)" }

    static let all: [MixedQuantize] = [
      MixedQuantize(straight: .eighth, triplet: .eighthTriplet),
      MixedQuantize(straight: .sixteenth, triplet: .eighthTriplet),
      MixedQuantize(straight: .sixteenth, triplet: .sixteenthTriplet),
      MixedQuantize(straight: .thirtySecond, triplet: .sixteenthTriplet),
    ]
  }

  /// While notes are being dragged: how far they would move, already snapped.
  nonisolated struct NoteDragPreview: Equatable {
    var offset: Tick
    var pitchOffset: Int
  }

  static let zoomRange: ClosedRange<Double> = 8...480

  unowned let window: ProjectWindowModel
  /// Rows are pitches, below the ruler, so `visibleRows` says which pitches are near the view.
  let scroll = ScrollState(rowHeight: Layout.rowHeight, rowsTop: Layout.rulerHeight)

  var pointsPerQuarterNote: Double = 64
  var gridSetting = GridSetting.automatic
  /// Whether notes snap to the grid as they're drawn, moved and resized. The grid still
  /// shows and Quantize still uses it when snapping is off.
  var isSnapEnabled = true
  var selectedNoteIDs: Set<MIDINote.ID> = []
  var dragPreview: NoteDragPreview?
  /// The velocity new notes get; follows the last note clicked, like Logic.
  var newNoteVelocity = 100
  /// The Piano Roll or the Step Editor (see PianoRollModel+StepEditor.swift).
  var editorKind = EditorKind.pianoRoll

  // Editing tools (see PianoRollModel+Editing.swift).

  var tool = PianoRollTool.pointer
  /// What dragging over steps changes in the Step Sequencer.
  var stepEditMode = StepEditMode.on
  /// Whether the pointer is over the Piano Roll, so T opens its tools there.
  @ObservationIgnored var isPointerOver = false
  /// Where the pointer is over the notes, so a right-click knows which note it's on.
  @ObservationIgnored var pointerLocation: CGPoint?
  /// How far quantizing moves notes toward the grid (1 all the way), and how much it swings
  /// every second grid line, from the Quantize menu.
  var quantizeStrength = 1.0
  var quantizeSwing = 0.0
  /// The length the Pencil gives a note it's clicked in, as in Logic: the last one drawn
  /// or resized.
  var lastNoteLength: Tick?
  /// A rubber band being dragged over the notes, in their coordinates.
  var marquee: CGRect?
  /// While the Velocity tool is dragged: each changed note's new velocity.
  var velocityToolPreview: [MIDINote.ID: Int]?
  /// While notes are Option-dragged: copies are made instead of moving them.
  var isCopyDrag = false
  /// While a note's edge is dragged: how far the selection's starts or ends would move.
  var resizePreview: ResizePreview?

  nonisolated struct ResizePreview: Equatable {
    var notes: Set<MIDINote.ID>
    var fromStart: Bool
    var delta: Tick
  }

  /// Whether the T menu is open for the Piano Roll (the last place clicked) rather than the
  /// tracks.
  var isToolMenuForPianoRoll: Bool {
    window.isShowingToolMenu && window.activeEditingArea == .pianoRoll && window.isEditorVisible && shownEditor == .pianoRoll
  }

  // MIDI Draw lane (see PianoRollModel+MIDIDraw.swift).

  /// Whether the MIDI Draw lane shows under the notes, as Logic's View › Show
  /// Automation/MIDI. Remembered between launches.
  var isMIDIDrawVisible = UserDefaults.standard.bool(forKey: PianoRollModel.midiDrawVisibleKey) {
    didSet {
      UserDefaults.standard.set(isMIDIDrawVisible, forKey: Self.midiDrawVisibleKey)
      if !isMIDIDrawVisible { selectedControlIDs = [] }
    }
  }
  /// What the lane shows and edits.
  var midiDrawParameter = MIDIDrawParameter.velocity
  /// The lane's height, dragged by its top edge and saved when the drag ends.
  var midiDrawHeight = PianoRollModel.savedMIDIDrawHeight
  var selectedControlIDs: Set<MIDIControlEvent.ID> = []
  /// While controller points are dragged or drawn: what they'd become.
  var controlPreview: ControlPreview?
  /// While velocity stalks are dragged: each changed note's new velocity.
  var velocityPreview: [MIDINote.ID: Int]?

  init(window: ProjectWindowModel) {
    self.window = window
  }

  // MARK: - What's being edited

  var region: Region? {
    window.editorRegionID.flatMap(window.project.region(withID:))
  }

  var track: Track? {
    guard let regionID = window.editorRegionID, let location = window.project.regionLocation(for: regionID) else {
      return nil
    }
    return window.project.tracks[location.track]
  }

  var notes: [MIDINote] {
    guard case .midi(let sequence) = region?.content else { return [] }
    return sequence.notes
  }

  /// The region's controllers, pitch bend and aftertouch.
  var controls: [MIDIControlEvent] {
    guard case .midi(let sequence) = region?.content else { return [] }
    return sequence.controls
  }

  func projectDidChange() {
    selectedNoteIDs.formIntersection(notes.map(\.id))
    selectedControlIDs.formIntersection(controls.map(\.id))
  }

  // MARK: - Geometry

  func x(for position: Tick) -> CGFloat {
    CGFloat(position.quarterNotes * pointsPerQuarterNote)
  }

  func position(forX x: CGFloat) -> Tick {
    .quarterNotes(Double(x) / pointsPerQuarterNote)
  }

  func y(forPitch pitch: Int) -> CGFloat {
    CGFloat(Layout.pitchCount - 1 - pitch) * Layout.rowHeight
  }

  func pitch(forY y: CGFloat) -> Int {
    min(max(Layout.pitchCount - 1 - Int((y / Layout.rowHeight).rounded(.down)), 0), Layout.pitchCount - 1)
  }

  /// Wide enough for the region plus room to extend it.
  var contentWidth: CGFloat {
    x(for: region?.length ?? Tick(3840)) + 320
  }

  func zoom(by factor: Double) {
    pointsPerQuarterNote = min(max(pointsPerQuarterNote * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
  }

  // MARK: - Grid

  var grid: Tick {
    if let ticks = gridSetting.ticks { return ticks }
    // Automatic: the finest straight division that is still at least 12 points wide. In a
    // compound meter (6/8, 12/8) the coarsest is the dotted-quarter beat, not a quarter.
    let signature = window.project.tempoMap.timeSignature(atBarIndex: window.project.tempoMap.bar(containing: region?.start ?? .zero).index)
    for ticks in [Tick(120), Tick(240), Tick(480), signature.isCompound ? signature.pulse : Tick(960)] where x(for: ticks) >= 12 {
      return ticks
    }
    return signature.ticksPerBar
  }

  /// The nearest grid line, measured from the bar line so odd meters snap correctly.
  func snap(_ localPosition: Tick) -> Tick {
    guard let region, isSnapEnabled, !ProjectWindowModel.isSnapBypassed else { return localPosition }
    let absolute = region.start + localPosition
    let barStart = window.project.tempoMap.bar(containing: absolute).start
    let steps = (Double((absolute - barStart).rawValue) / Double(grid.rawValue)).rounded()
    return barStart + grid * Int64(steps) - region.start
  }

  /// Like `snap`, but rounding down, for placing a note in the grid cell that was clicked.
  func snapDown(_ localPosition: Tick) -> Tick {
    guard let region, isSnapEnabled, !ProjectWindowModel.isSnapBypassed else { return localPosition }
    let absolute = region.start + localPosition
    let barStart = window.project.tempoMap.bar(containing: absolute).start
    let steps = (Double((absolute - barStart).rawValue) / Double(grid.rawValue)).rounded(.down)
    return barStart + grid * Int64(steps) - region.start
  }

  // MARK: - Editing

  func select(_ noteID: MIDINote.ID, extending: Bool) {
    window.activeEditingArea = .pianoRoll
    selectedControlIDs = []
    if extending {
      if selectedNoteIDs.contains(noteID) {
        selectedNoteIDs.remove(noteID)
      } else {
        selectedNoteIDs.insert(noteID)
      }
    } else if !selectedNoteIDs.contains(noteID) {
      selectedNoteIDs = [noteID]
    }
    if let note = notes.first(where: { $0.id == noteID }) {
      newNoteVelocity = note.velocity
    }
  }

  /// Adds a one-grid-step note in the cell at `localPosition` and selects it.
  func addNote(at localPosition: Tick, pitch: Int) {
    guard let region, localPosition >= .zero else { return }
    let note = MIDINote(pitch: pitch, velocity: newNoteVelocity, start: snapDown(localPosition), length: grid)
    window.perform(AddNotes([note], to: region.id))
    window.activeEditingArea = .pianoRoll
    selectedNoteIDs = [note.id]
    preview(pitch: pitch, velocity: note.velocity)
  }

  /// Deletes the selected controller points if the MIDI Draw lane has any (clicking a note
  /// or hiding the lane clears them), otherwise the selected notes.
  func deleteSelection() {
    guard let region else { return }
    if !selectedControlIDs.isEmpty {
      window.perform(DeleteControlEvents(selectedControlIDs, from: region.id))
      selectedControlIDs = []
    } else if !selectedNoteIDs.isEmpty {
      window.perform(DeleteNotes(selectedNoteIDs, from: region.id))
    }
  }

  func moveSelection(by offset: Tick, pitchOffset: Int) {
    guard let region, offset != .zero || pitchOffset != 0 else { return }
    let moved = notes.filter { selectedNoteIDs.contains($0.id) }.map { note in
      var copy = note
      copy.start = max(.zero, note.start + offset)
      copy.pitch = min(max(note.pitch + pitchOffset, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound)
      return copy
    }
    window.perform(UpdateNotes(moved, in: region.id, actionName: moved.count == 1 ? "Move Note" : "Move Notes"))
    if pitchOffset != 0, let first = moved.first {
      preview(pitch: first.pitch, velocity: first.velocity)
    }
  }

  func resize(_ noteID: MIDINote.ID, to length: Tick) {
    guard let region, var note = notes.first(where: { $0.id == noteID }), length != note.length else { return }
    note.length = max(length, Tick(1))
    window.perform(UpdateNotes([note], in: region.id, actionName: "Resize Note"))
  }

  /// Quantizes the selected notes, or every note when none are selected.
  func quantize(to setting: GridSetting) {
    guard let region else { return }
    let grid = setting.ticks ?? self.grid
    window.perform(QuantizeNotes(in: region.id, noteIDs: selectedNoteIDs.isEmpty ? nil : selectedNoteIDs, grid: grid))
  }

  func setVelocity(_ velocity: Int) {
    guard let region, !selectedNoteIDs.isEmpty else { return }
    let clamped = min(max(velocity, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
    let changed = notes.filter { selectedNoteIDs.contains($0.id) }.map { note in
      var copy = note
      copy.velocity = clamped
      return copy
    }
    window.perform(UpdateNotes(changed, in: region.id, actionName: "Change Velocity"))
    newNoteVelocity = clamped
  }

  func preview(pitch: Int, velocity: Int = 100) {
    guard let track else { return }
    window.engine.previewNote(pitch: pitch, velocity: velocity, onTrack: track.id)
  }

  /// Logic's octave numbering: middle C (MIDI 60) is C3.
  static func noteName(_ pitch: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[pitch % 12])\(pitch / 12 - 2)"
  }

  static func isBlackKey(_ pitch: Int) -> Bool {
    [1, 3, 6, 8, 10].contains(pitch % 12)
  }

  /// Logic-style velocity colors: blue for soft notes through green and yellow to red for
  /// loud ones.
  static func color(forVelocity velocity: Int) -> Color {
    let amount = Double(min(max(velocity, 1), 127) - 1) / 126
    // Logic's velocity colours: violet for soft notes through blue, green and yellow to red.
    return Color(hue: 0.76 * (1 - amount), saturation: 0.7, brightness: 0.94)
  }
}
