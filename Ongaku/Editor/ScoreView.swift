//
//  ScoreView.swift
//  Ongaku
//

import AppKit
import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Score editor: the open MIDI region as notation, wrapped into lines that fit the
/// pane. The Pointer selects and drags notes (up and down the key's scale, sideways by the
/// display quantize), the Pencil writes notes of the chosen value, the Eraser deletes them.
/// The notes are the same ones the Piano Roll edits, with the same undo.
struct ScoreView: View {
  let model: PianoRollModel
  let region: Region

  @State private var drag: DragState?

  private struct DragState {
    var noteID: MIDINote.ID
    var start: CGPoint
    var translation: CGSize = .zero
    /// Display-quantize steps per point, around the dragged note.
    var stepWidth: CGFloat
  }

  var body: some View {
    GeometryReader { proxy in
      let layout = model.scoreLayout(for: region)
      let score = EngravedScore(layout: layout, width: proxy.size.width, space: model.scoreSpace, margin: model.scoreSpace * 3)
      ScrollView(.vertical) {
        ZStack(alignment: .topLeading) {
          Canvas { context, _ in
            ScoreRenderer(score: score, palette: .screen, selected: model.selectedNoteIDs, dragOffset: snappedOffset(score))
              .draw(in: context)
          }
          ScorePlayhead(model: model, score: score)
        }
        .frame(width: proxy.size.width, height: max(proxy.size.height, score.size.height))
        .contentShape(.rect)
        .gesture(
          DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in dragged(value, score: score) }
            .onEnded { value in ended(value, score: score) })
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("score")
        .accessibilityLabel("Score")
        .accessibilityValue(accessibilitySummary(layout))
      }
    }
    .background(Theme.lanes)
  }

  // MARK: - Gestures

  private func head(at point: CGPoint, in score: EngravedScore) -> PlacedHead? {
    score.placedHeads.min { distance($0.center, point) < distance($1.center, point) }
      .flatMap { distance($0.center, point) <= score.space * 1.1 ? $0 : nil }
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

  private func dragged(_ value: DragGesture.Value, score: EngravedScore) {
    model.window.beginEditing(in: .pianoRoll)
    guard model.scoreTool == .pointer else { return }
    if drag == nil {
      guard let hit = head(at: value.startLocation, in: score) else { return }
      model.selectScoreNote(hit.note.noteID, extending: NSEvent.modifierFlags.contains(.shift))
      drag = DragState(noteID: hit.note.noteID, start: value.startLocation, stepWidth: stepWidth(around: hit, in: score))
    }
    drag?.translation = value.translation
  }

  private func ended(_ value: DragGesture.Value, score: EngravedScore) {
    defer { drag = nil }
    let moved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
    switch model.scoreTool {
    case .pointer:
      guard let drag else {
        if !moved { model.deselectAll() }
        return
      }
      guard moved else { return }
      let steps = Int((value.translation.width / max(1, drag.stepWidth)).rounded())
      let diatonic = Int((-value.translation.height / (score.space / 2)).rounded())
      let position = model.notes.first { $0.id == drag.noteID }.map { region.start + $0.start } ?? region.start
      model.moveScoreSelection(by: steps, diatonicSteps: model.isScoreDrumPart ? 0 : diatonic, key: model.window.project.key(at: position))
    case .pencil:
      guard !moved, let place = score.locate(value.location) else { return }
      let system = score.systems[place.system]
      let measure = system.measures[place.measure]
      let tick = score.tick(atX: value.location.x, in: measure, grid: model.scoreOptions.quantize)
      let diatonic = score.diatonic(atY: value.location.y, staff: place.staff, in: system)
      let pitch = model.isScoreDrumPart
        ? ScorePitch.drum(diatonic: diatonic) : ScorePitch.pitch(diatonic: diatonic, in: model.window.project.key(at: tick))
      model.writeScoreNote(at: tick, pitch: pitch)
    case .eraser:
      if let hit = head(at: value.location, in: score) { model.eraseScoreNote(hit.note.noteID) }
    }
  }

  /// How far a display-quantize step is on the page near a note.
  private func stepWidth(around head: PlacedHead, in score: EngravedScore) -> CGFloat {
    let system = score.systems[head.system]
    guard let measure = system.measures.first(where: { head.event.start >= $0.measure.start && head.event.start < $0.measure.end })
    else { return score.space * 2 }
    let quantize = model.scoreOptions.quantize
    let width = measure.x(at: min(measure.measure.end - Tick(1), head.event.start + quantize)) - measure.x(at: head.event.start)
    return max(score.space, width)
  }

  /// The drag so far, moved in whole steps (so the notes jump to where they'll land).
  private func snappedOffset(_ score: EngravedScore) -> CGSize {
    guard let drag else { return .zero }
    let steps = (drag.translation.width / max(1, drag.stepWidth)).rounded()
    let half = score.space / 2
    let diatonic = model.isScoreDrumPart ? 0 : (drag.translation.height / half).rounded()
    return CGSize(width: steps * drag.stepWidth, height: diatonic * half)
  }

  private func accessibilitySummary(_ layout: ScoreLayout) -> String {
    let notes = layout.measures.flatMap { $0.events.flatMap { $0 } }.filter { !$0.isRest && !$0.notes.contains(where: \.isTiedFromPrevious) }
    let clefs = layout.staves.map(\.clef.rawValue).joined(separator: " and ")
    return "\(layout.measures.count) bars, \(notes.count) notes, \(clefs) clef"
  }
}

/// The playhead over the score; it reads the song position itself, so only it redraws as
/// the song plays.
private struct ScorePlayhead: View {
  let model: PianoRollModel
  let score: EngravedScore

  var body: some View {
    let position = model.window.engine.playheadPosition
    Canvas { context, _ in
      ScoreRenderer(score: score, palette: .screen, playhead: position).drawPlayheadOnly(in: context)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

extension ScoreRenderer {
  /// Just the playhead (the score itself is drawn underneath).
  func drawPlayheadOnly(in context: GraphicsContext) {
    guard let playhead, let place = score.place(playhead) else { return }
    let system = score.systems[place.system]
    guard let top = system.staffTops.first, let bottom = system.staffTops.last else { return }
    var path = Path()
    path.move(to: CGPoint(x: place.x, y: top - score.space * 2))
    path.addLine(to: CGPoint(x: place.x, y: bottom + score.space * 6))
    context.stroke(path, with: .color(palette.playhead.opacity(0.9)), lineWidth: 1.5)
  }
}

/// The Score editor's controls in the editor header: tools, the Pencil's note value, display
/// quantize, staves and chord symbols.
struct ScoreControls: View {
  let model: PianoRollModel

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 2) {
        ForEach(ScoreTool.allCases) { tool in
          Button(tool.title, systemImage: tool.symbolName) { model.scoreTool = tool }
            .buttonStyle(ThemeButtonStyle(isOn: model.scoreTool == tool, onColor: Theme.accent, width: 24, height: 20))
            .help(tool.help)
            .accessibilityAddTraits(model.scoreTool == tool ? .isSelected : [])
        }
      }
      if model.scoreTool == .pencil {
        Picker("Note Value", selection: Binding(get: { model.scoreNoteValue }, set: { model.scoreNoteValue = $0 })) {
          ForEach(NoteValue.Base.pencilValues, id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
        .help("The value of the notes the Pencil writes.")
      }
      Picker("Quantize", selection: Binding(get: { model.scoreOptions.quantize }, set: { model.scoreOptions.quantize = $0 })) {
        ForEach(ScoreOptions.quantizeValues, id: \.ticks) { Text($0.title).tag($0.ticks) }
      }
      .fixedSize()
      .help("Display quantize: the shortest value shown, so a played part reads cleanly. The notes themselves don't move.")
      Button("Triplets", systemImage: "3.square") { model.scoreOptions.allowsTriplets.toggle() }
        .buttonStyle(ThemeButtonStyle(isOn: model.scoreOptions.allowsTriplets, onColor: Theme.accent, width: 26, height: 20))
        .help("Write notes played in thirds of a beat as triplets.")
        .accessibilityValue(model.scoreOptions.allowsTriplets ? "On" : "Off")
      if !model.isScoreDrumPart {
        Picker("Staff", selection: Binding(get: { model.scoreOptions.clef }, set: { model.scoreOptions.clef = $0 })) {
          ForEach([ClefChoice.automatic, .treble, .bass, .grand], id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
        .help("Which staff or staves the part is written on. Automatic chooses from the notes' range, splitting at middle C.")
      }
      Button("Chord Symbols", systemImage: "textformat") { model.scoreOptions.showsChordSymbols.toggle() }
        .buttonStyle(ThemeButtonStyle(isOn: model.scoreOptions.showsChordSymbols, onColor: Theme.accent, width: 26, height: 20))
        .help("Show the Chord track's chords over the staff.")
        .accessibilityValue(model.scoreOptions.showsChordSymbols ? "On" : "Off")
    }
  }
}

#Preview("Score") {
  ScorePreview()
    .frame(width: 900, height: 420)
}

/// Keeps the window model alive: the editor's model refers to it without owning it.
private struct ScorePreview: View {
  @State private var window: ProjectWindowModel = {
    var keys = Track(name: "Piano", kind: .softwareInstrument)
    let q = Tick.perQuarterNote
    func note(_ pitch: Int, _ beat: Double, _ beats: Double) -> MIDINote {
      MIDINote(pitch: pitch, velocity: 90, start: .quarterNotes(beat), length: .quarterNotes(beats))
    }
    let melody = [
      note(76, 0, 1), note(74, 1, 0.5), note(72, 1.5, 0.5), note(74, 2, 1), note(76, 3, 1),
      note(77, 4, 1.5), note(79, 5.5, 0.5), note(81, 6, 2),
      note(79, 8, 1.0 / 3), note(78, 8 + 1.0 / 3, 1.0 / 3), note(79, 8 + 2.0 / 3, 1.0 / 3), note(81, 9, 0.25), note(82, 9.25, 0.25),
      note(81, 9.5, 0.5), note(79, 10, 2),
      note(77, 12, 3), note(76, 15, 2),
    ]
    let bass = [note(48, 0, 4), note(43, 4, 2), note(45, 6, 2), note(48, 8, 2), note(50, 10, 2), note(41, 12, 4), note(48, 16, 1)]
    _ = q
    let region = Region(name: "Theme", start: .zero, length: .quarterNotes(20), content: .midi(MIDISequence(notes: melody + bass)))
    keys.regions = [region]
    var project = Project(tracks: [keys])
    project.chords = [
      ChordChange(position: .zero, chord: Chord(name: "C")!), ChordChange(position: .quarterNotes(4), chord: Chord(name: "F")!),
      ChordChange(position: .quarterNotes(8), chord: Chord(name: "Am7")!), ChordChange(position: .quarterNotes(12), chord: Chord(name: "F")!),
    ]
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    window.editorRegionID = region.id
    window.pianoRoll.editorKind = .score
    window.pianoRoll.selectedNoteIDs = [melody[5].id]
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
