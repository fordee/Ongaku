//
//  StepEditorView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// Logic's Step Editor: a row per note (each drum of a kit) or controller, with each event a
/// bar on the step grid as tall as its velocity or value. Click a step to set it to the
/// height clicked (adding an event there), drag across steps to paint them, double-click a
/// bar to remove it.
struct StepEditorView: View {
  let model: PianoRollModel
  let region: Region

  static let laneHeight: CGFloat = 30
  static let nameWidth: CGFloat = 120

  var body: some View {
    let lanes = model.stepLanes
    // Worked out once for every lane: looking each step up in the notes would take a
    // search per step, which is slow on long regions.
    let values = model.stepValues()
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(spacing: 0) {
        ForEach(lanes) { lane in
          StepLaneRow(model: model, region: region, lane: lane, values: values[lane] ?? [:])
        }
      }
    }
    .scrollIndicators(.automatic)
    .background(Theme.lanes)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Step Editor")
  }
}

private struct StepLaneRow: View {
  let model: PianoRollModel
  let region: Region
  let lane: StepLane
  /// The lane's values by step.
  let values: [Int: Int]

  /// While a click or drag paints the lane: the new value of each step touched.
  @State private var painted: [Int: Int] = [:]

  private var height: CGFloat { StepEditorView.laneHeight }

  var body: some View {
    let stepWidth = model.x(for: model.stepLength)
    let steps = model.stepCount
    let isNote = if case .note = lane { true } else { false }
    HStack(spacing: 0) {
      Text(model.name(of: lane))
        .font(Theme.font(10, weight: .medium))
        .foregroundStyle(isNote ? Theme.text : Theme.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: StepEditorView.nameWidth, height: height, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }

      Canvas { context, size in
        var grid = Path()
        var bars = Path()
        let beat = model.x(for: .quarterNotes(1))
        for step in 0..<steps {
          let x = CGFloat(step) * stepWidth
          grid.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
          let value = painted[step] ?? values[step]
          guard let value else { continue }
          let fraction = CGFloat(value - lane.valueRange.lowerBound) / CGFloat(lane.valueRange.upperBound - lane.valueRange.lowerBound)
          let barHeight = max(2, (size.height - 4) * fraction)
          bars.addRect(CGRect(x: x + 2, y: size.height - 2 - barHeight, width: max(stepWidth - 4, 2), height: barHeight))
        }
        context.fill(grid, with: .color(Theme.beatLine))
        // Beats stand out from steps.
        var beats = Path()
        var position: CGFloat = 0
        while position < size.width {
          beats.addRect(CGRect(x: position, y: 0, width: 1, height: size.height))
          position += beat
        }
        context.fill(beats, with: .color(Theme.barLine))
        context.fill(bars, with: .color(isNote ? Theme.accent : Theme.solo.opacity(0.85)))
      }
      .frame(width: CGFloat(steps) * stepWidth, height: height)
      .contentShape(.rect)
      .gesture(paint(stepWidth: stepWidth))
      .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
        model.clearStep(lane, at: Int(tap.location.x / stepWidth))
      })
    }
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    .accessibilityElement()
    .accessibilityLabel(model.name(of: lane))
    .accessibilityValue(accessibilityValue(steps: steps))
    .accessibilityIdentifier("step-lane")
  }

  /// Clicking or dragging sets each step touched to the value at the pointer's height.
  private func paint(stepWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { drag in
        let step = Int(drag.location.x / stepWidth)
        let fraction = 1 - min(max((drag.location.y - 2) / (height - 4), 0), 1)
        let range = lane.valueRange
        painted[step] = range.lowerBound + Int((Double(range.upperBound - range.lowerBound) * fraction).rounded())
      }
      .onEnded { _ in
        model.setStepValues(painted, in: lane)
        painted = [:]
      }
  }

  private func accessibilityValue(steps: Int) -> String {
    let filled = values.keys.filter { $0 < steps }.sorted().map { "\($0 + 1)" }
    return filled.isEmpty ? "Empty" : "Steps \(filled.joined(separator: ", "))"
  }
}

#Preview {
  StepEditorPreview()
    .frame(width: 760, height: 420)
}

/// Keeps the window model alive: the editor's model refers to it without owning it.
private struct StepEditorPreview: View {
  @State private var window: ProjectWindowModel = {
    var drums = Track(name: "Drums", kind: .softwareInstrument)
    drums.channel.instrument = .generalMIDIPercussion(kit: 0)
    let sixteenth = Tick(240)
    var notes: [MIDINote] = []
    for step in 0..<16 {
      notes.append(MIDINote(pitch: 42, velocity: step % 2 == 0 ? 110 : 60, start: sixteenth * Int64(step), length: sixteenth))
      if step % 8 == 0 { notes.append(MIDINote(pitch: 36, velocity: 127, start: sixteenth * Int64(step), length: sixteenth)) }
      if step % 8 == 4 { notes.append(MIDINote(pitch: 38, velocity: 100, start: sixteenth * Int64(step), length: sixteenth)) }
    }
    let region = Region(name: "Beat", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: notes)))
    drums.regions = [region]
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [drums])))
    window.editorRegionID = region.id
    window.pianoRoll.editorKind = .stepEditor
    window.pianoRoll.pointsPerQuarterNote = 120
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
