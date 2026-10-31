//
//  FlexPitchEditorView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// Logic's Flex Pitch editor: the notes found in an audio region, drawn like a piano roll at
/// the pitch they're sung. Drag a note up or down to retune it (in semitones from where it
/// was sung, to a whole note); double-click it to put it back.
struct FlexPitchEditorView: View {
  let model: PianoRollModel
  let region: Region

  static let rowHeight: CGFloat = 14
  static let nameWidth: CGFloat = 44

  var body: some View {
    if let notes = model.window.detectedNotes(in: region) {
      if notes.isEmpty {
        ContentUnavailableView(
          "No Notes Found", systemImage: "waveform.path",
          description: Text("Flex Pitch works on monophonic audio: one voice or instrument playing one note at a time."))
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PitchGrid(model: model, region: region, notes: notes)
      }
    } else {
      ProgressView("Finding notes…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct PitchGrid: View {
  let model: PianoRollModel
  let region: Region
  let notes: [DetectedNote]

  /// The note being dragged, and how far (in semitones, whole).
  @State private var drag: (index: Int, semitones: Double)?

  private var rowHeight: CGFloat { FlexPitchEditorView.rowHeight }

  var body: some View {
    let window = model.window
    let edits = notes.map { window.pitchEdit(for: $0, in: region)?.semitones ?? 0 }
    let sounding = notes.indices.map { notes[$0].pitch + (drag?.index == $0 ? drag!.semitones : edits[$0]) }
    // Room for every note, sung and retuned, with a few semitones either side.
    let highest = Int(((notes.map(\.pitch) + sounding).max() ?? 72).rounded(.up)) + 3
    let lowest = Int(((notes.map(\.pitch) + sounding).min() ?? 48).rounded(.down)) - 3
    let rows = highest - lowest + 1
    let width = max(model.x(for: region.length), 1)
    let tempoMap = window.project.tempoMap
    let regionStart = tempoMap.seconds(at: region.start)
    let x: (Double) -> CGFloat = { seconds in
      model.x(for: tempoMap.tickPosition(atSeconds: regionStart + seconds) - region.start)
    }
    let rowHeight = rowHeight
    // The middle of a pitch's row, so a note sung in tune sits in its row.
    let y: (Double) -> CGFloat = { pitch in CGFloat(Double(highest) - pitch + 0.5) * rowHeight }

    ScrollView([.horizontal, .vertical]) {
      HStack(alignment: .top, spacing: 0) {
        // Note names down the left, like a keyboard.
        VStack(spacing: 0) {
          ForEach((lowest...highest).reversed(), id: \.self) { pitch in
            Text(PianoRollModel.noteName(pitch))
              .font(Theme.monospaced(9))
              .foregroundStyle(PianoRollModel.isBlackKey(pitch) ? Theme.tertiaryText : Theme.secondaryText)
              .frame(width: FlexPitchEditorView.nameWidth, height: rowHeight, alignment: .trailing)
              .padding(.trailing, 4)
              .background(PianoRollModel.isBlackKey(pitch) ? Color.black.opacity(0.25) : Color.clear)
          }
        }
        .background(Theme.panel)

        ZStack(alignment: .topLeading) {
          Canvas { context, size in
            var lines = Path()
            for row in 0...rows {
              lines.addRect(CGRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: 0.5))
            }
            context.fill(lines, with: .color(Theme.beatLine))
          }
          ForEach(notes.indices, id: \.self) { index in
            let note = notes[index]
            let pitch = sounding[index]
            let isMoved = abs(pitch - note.pitch) > 0.001
            let noteX = x(note.start)
            let noteWidth = max(x(note.end) - noteX, 4)
            ZStack {
              // Where it was sung, when it's been moved.
              if isMoved {
                RoundedRectangle(cornerRadius: 4)
                  .strokeBorder(Theme.secondaryText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                  .frame(width: noteWidth, height: rowHeight - 2)
                  .offset(y: y(note.pitch) - y(pitch))
              }
              RoundedRectangle(cornerRadius: 4)
                .fill((model.track?.color.color ?? Theme.accent).opacity(isMoved ? 0.95 : 0.7))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.4)))
                .frame(width: noteWidth, height: rowHeight - 2)
            }
            .frame(width: noteWidth, height: rowHeight - 2)
            .offset(x: noteX, y: y(pitch) - rowHeight / 2 + 1)
            .gesture(
              DragGesture(minimumDistance: 2)
                .onChanged { value in
                  // Whole semitones: the note lands on the nearest one.
                  let target = (note.pitch + edits[index] - Double(value.translation.height / rowHeight)).rounded()
                  drag = (index, target - note.pitch)
                }
                .onEnded { _ in
                  if let drag { window.retune(note, in: region.id, by: drag.semitones) }
                  drag = nil
                }
            )
            .onTapGesture(count: 2) { window.retune(note, in: region.id, by: 0) }
            .help("\(PianoRollModel.noteName(Int(note.pitch.rounded())))\(isMoved ? " → " + PianoRollModel.noteName(Int(pitch.rounded())) : ""): drag to retune, double-click to reset")
            .accessibilityElement()
            .accessibilityLabel("Note \(PianoRollModel.noteName(Int(pitch.rounded())))")
            .accessibilityValue(isMoved ? String(format: "%+.2f semitones", pitch - note.pitch) : "As sung")
            .accessibilityIdentifier("flex-pitch-note")
          }
        }
        .frame(width: width, height: CGFloat(rows) * rowHeight, alignment: .topLeading)
      }
    }
    .background(Theme.lanes)
  }
}

#Preview {
  FlexPitchPreview()
    .frame(width: 760, height: 360)
}

/// Keeps the window model alive: the editor's model refers to it without owning it.
private struct FlexPitchPreview: View {
  @State private var window: ProjectWindowModel = {
    let file = AudioFileReference(fileName: "Vocal.caf", sampleRate: 48_000, channelCount: 1, frameCount: 192_000)
    let notes = [
      DetectedNote(start: 0.1, end: 0.6, pitch: 64.2), DetectedNote(start: 0.7, end: 1.1, pitch: 62.9),
      DetectedNote(start: 1.2, end: 2.0, pitch: 60.1), DetectedNote(start: 2.3, end: 3.6, pitch: 67.4),
    ]
    let region = Region(
      name: "Vocal", start: .zero, length: .quarterNotes(8),
      content: .audio(AudioRegionContent(fileID: file.id, pitchEdits: [PitchEdit(start: 2.3, end: 3.6, semitones: 1.6)])))
    let track = Track(name: "Vocal", kind: .audio, regions: [region], flexMode: .pitch)
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track], audioFiles: [file])))
    if let key = window.detectedNotesKey(for: region) { window.detectedNotes[key] = notes }
    window.editorRegionID = region.id
    window.pianoRoll.pointsPerQuarterNote = 80
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
