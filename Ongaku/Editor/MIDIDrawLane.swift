//
//  MIDIDrawLane.swift
//  Ongaku
//

import AppKit
import OngakuCore
import SwiftUI

/// Logic's MIDI Draw lane, under the piano roll's notes and scrolling sideways with them.
///
/// For Note Velocity it shows a stalk per note: drag a stalk up or down (all the selected
/// notes move together if it's one of them), or drag across empty space to sweep the
/// velocities under the pointer to its height. For controllers, pitch bend and aftertouch
/// it shows the values as steps, the way MIDI plays them: click empty space to add a point,
/// drag points to move them, drag across empty space to draw freehand, and press Delete to
/// remove the selected points.
///
/// Everything is drawn in one `Canvas` and hit-tested by position, so a pitch bend with
/// thousands of points stays quick.
struct MIDIDrawLane: View {
  let model: PianoRollModel
  let region: Region

  @State private var interaction: Interaction?
  @State private var readout: Readout?

  /// Room above the top value and below the bottom one, so points there can be grabbed.
  static let inset: CGFloat = 7
  private static let hitRadius: CGFloat = 6

  private enum Interaction {
    /// Dragging stalks: the notes' velocities when the drag began.
    case velocityDrag(original: [MIDINote.ID: Int], startY: CGFloat)
    /// Sweeping across stalks, setting each to the pointer's height.
    case velocitySweep(lastX: CGFloat)
    /// Dragging controller points from where the drag began.
    case movePoints(ids: Set<MIDIControlEvent.ID>, start: CGPoint)
    /// Pressed on empty space: a click adds a point, moving turns it into a stroke.
    case pressed(start: CGPoint)
    /// Drawing freehand: the samples so far.
    case stroke(samples: [(position: Tick, value: Int)])
    /// Nothing to edit (poly aftertouch with no note selected).
    case inactive
  }

  private struct Readout {
    var location: CGPoint
    var text: String
  }

  var body: some View {
    let height = model.midiDrawHeight
    ZStack(alignment: .topLeading) {
      Rectangle().fill(Theme.panel)
      EditorGridLines(model: model, region: region, height: height)
      // Outside the region: points here are kept but don't play.
      Rectangle()
        .fill(Color.black.opacity(0.2))
        .frame(width: max(0, model.contentWidth - model.x(for: region.length)), height: height)
        .offset(x: model.x(for: region.length))
      LaneCanvas(model: model, region: region, height: height)
      if model.midiDrawParameter == .polyPressure, model.drawnKind == nil {
        Text("Select one note to edit its aftertouch.")
          .font(Theme.font(11))
          .foregroundStyle(Theme.secondaryText)
          .padding(.leading, 12 + max(0, model.scroll.offset.x))
          .frame(height: height)
      }
      if let readout {
        Text(readout.text)
          .font(Theme.monospaced(10, weight: .semibold))
          .foregroundStyle(Theme.text)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.black.opacity(0.75)))
          .fixedSize()
          .offset(x: readout.location.x + 10, y: max(0, readout.location.y - 22))
          .allowsHitTesting(false)
      }
    }
    .frame(width: model.contentWidth, height: height, alignment: .topLeading)
    .clipped()
    .contentShape(.rect)
    .gesture(laneGesture)
    .overlay(alignment: .top) { LaneResizeEdge(model: model) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("MIDI Draw: \(model.midiDrawParameter.name)")
    .accessibilityIdentifier("midi-draw-lane")
  }

  // MARK: - Geometry

  private var height: CGFloat { model.midiDrawHeight }

  private var valueRange: ClosedRange<Int> { model.midiDrawParameter.valueRange }

  private func y(forValue value: Int) -> CGFloat {
    Self.y(forValue: value, in: valueRange, height: height)
  }

  static func y(forValue value: Int, in range: ClosedRange<Int>, height: CGFloat) -> CGFloat {
    let span = CGFloat(range.upperBound - range.lowerBound)
    let fraction = span > 0 ? CGFloat(value - range.lowerBound) / span : 0
    return inset + (1 - fraction) * (height - inset * 2)
  }

  private func value(forY y: CGFloat) -> Int {
    let usable = max(height - Self.inset * 2, 1)
    let fraction = 1 - (y - Self.inset) / usable
    let value = Int((Double(valueRange.lowerBound) + Double(fraction) * Double(valueRange.upperBound - valueRange.lowerBound)).rounded())
    return min(max(value, valueRange.lowerBound), valueRange.upperBound)
  }

  private func showReadout(_ value: Int, at location: CGPoint) {
    readout = Readout(location: location, text: "\(model.midiDrawParameter.name): \(model.midiDrawParameter.label(for: value))")
  }

  // MARK: - Hit testing

  /// The note whose stalk is under `x`, preferring the one whose head is nearest `y`.
  private func stalk(at location: CGPoint) -> MIDINote? {
    model.notes
      .filter { abs(model.x(for: $0.start) + 1 - location.x) <= Self.hitRadius - 2 }
      .min { abs(y(forValue: $0.velocity) - location.y) < abs(y(forValue: $1.velocity) - location.y) }
  }

  /// The controller point nearest `location`, if it's within reach.
  private func point(at location: CGPoint) -> MIDIControlEvent? {
    let candidates = model.drawnControls.filter {
      abs(model.x(for: $0.position) - location.x) <= Self.hitRadius && abs(y(forValue: $0.value) - location.y) <= Self.hitRadius
    }
    return candidates.min { lhs, rhs in
      hypot(model.x(for: lhs.position) - location.x, y(forValue: lhs.value) - location.y)
        < hypot(model.x(for: rhs.position) - location.x, y(forValue: rhs.value) - location.y)
    }
  }

  // MARK: - Gestures

  private var laneGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { drag in
        if interaction == nil {
          interaction = begin(at: drag.startLocation)
        }
        update(drag)
      }
      .onEnded { drag in
        finish(drag)
        interaction = nil
        readout = nil
      }
  }

  private func begin(at location: CGPoint) -> Interaction {
    model.window.beginEditing(in: .pianoRoll)
    let extending = NSEvent.modifierFlags.contains(.shift)
    if model.midiDrawParameter == .velocity {
      if let note = stalk(at: location) {
        if !model.selectedNoteIDs.contains(note.id) {
          model.select(note.id, extending: extending)
        }
        let targets = model.notes.filter { model.selectedNoteIDs.contains($0.id) }
        return .velocityDrag(original: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.velocity) }), startY: location.y)
      }
      return .velocitySweep(lastX: location.x)
    }
    guard model.drawnKind != nil else { return .inactive }
    if let point = point(at: location) {
      model.selectControl(point.id, extending: extending)
      return .movePoints(ids: model.selectedControlIDs, start: location)
    }
    if !extending {
      model.selectedControlIDs = []
    }
    return .pressed(start: location)
  }

  private func update(_ drag: DragGesture.Value) {
    let location = CGPoint(x: drag.location.x, y: min(max(drag.location.y, 0), height))
    switch interaction {
    case .velocityDrag(let original, let startY):
      let offset = value(forY: location.y) - value(forY: startY)
      model.velocityPreview = original.mapValues {
        min(max($0 + offset, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
      }
      if let first = model.velocityPreview?.values.first {
        showReadout(first, at: location)
      }

    case .velocitySweep(let lastX):
      // Notes between the last pointer position and this one take the pointer's height;
      // with a selection, only selected notes do.
      let value = value(forY: location.y)
      let range = min(lastX, location.x) - 2...max(lastX, location.x) + 2
      var preview = model.velocityPreview ?? [:]
      for note in model.notes where range.contains(model.x(for: note.start) + 1) {
        if model.selectedNoteIDs.isEmpty || model.selectedNoteIDs.contains(note.id) {
          preview[note.id] = min(max(value, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
        }
      }
      model.velocityPreview = preview
      interaction = .velocitySweep(lastX: location.x)
      showReadout(value, at: location)

    case .movePoints(let ids, let start):
      let offset = model.position(forX: location.x) - model.position(forX: start.x)
      let valueOffset = value(forY: location.y) - value(forY: start.y)
      let moved = model.movedControls(ids, by: offset, valueOffset: valueOffset)
      model.controlPreview = PianoRollModel.ControlPreview(events: moved)
      if let first = moved.first {
        showReadout(first.value, at: location)
      }

    case .pressed(let start):
      if hypot(location.x - start.x, location.y - start.y) > 3 {
        interaction = .stroke(samples: [(model.position(forX: start.x), value(forY: start.y))])
        update(drag)
      } else {
        showReadout(value(forY: start.y), at: start)
      }

    case .stroke(var samples):
      // Fill in between pointer events so a quick stroke still makes a smooth curve.
      let position = max(.zero, model.position(forX: location.x))
      let value = value(forY: location.y)
      if let last = samples.last {
        let steps = Int(abs((position - last.position).rawValue) / 30)
        if steps > 1 {
          for step in 1..<steps {
            let fraction = Double(step) / Double(steps)
            let between = last.position + Tick(Int64((Double((position - last.position).rawValue) * fraction).rounded()))
            samples.append((between, last.value + Int((Double(value - last.value) * fraction).rounded())))
          }
        }
      }
      samples.append((position, value))
      interaction = .stroke(samples: samples)
      let positions = samples.map(\.position)
      let range = (positions.min() ?? position)...(positions.max() ?? position)
      let kind = model.drawnKind
      let channel = model.drawnChannel
      let covered = model.controls.filter { $0.kind == kind && $0.channel == channel && range.contains($0.position) }
      model.controlPreview = PianoRollModel.ControlPreview(
        events: model.strokeEvents(samples), hiddenIDs: Set(covered.map(\.id)))
      showReadout(value, at: location)

    case .inactive, nil:
      break
    }
  }

  private func finish(_ drag: DragGesture.Value) {
    switch interaction {
    case .velocityDrag, .velocitySweep:
      model.commitVelocityPreview()
    case .movePoints:
      if model.controlPreview?.events.contains(where: { event in
        model.controls.first { $0.id == event.id } != event
      }) == true {
        model.commitControlPreview()
      } else {
        model.controlPreview = nil
      }
    case .pressed(let start):
      model.addControlPoint(at: max(.zero, model.position(forX: start.x)), value: value(forY: start.y))
    case .stroke(let samples):
      let positions = samples.map(\.position)
      if let first = positions.min(), let last = positions.max() {
        model.commitControlPreview(drawnOver: first...last)
      }
    case .inactive, nil:
      break
    }
  }
}

/// The lane's drawing: velocity stalks, or controller values as steps through their points.
private struct LaneCanvas: View {
  let model: PianoRollModel
  let region: Region
  let height: CGFloat

  var body: some View {
    let range = model.scroll.renderRange
    let parameter = model.midiDrawParameter
    let valueRange = parameter.valueRange
    let color = model.track?.color.color ?? Theme.accent
    let regionLength = region.length
    // Read everything from the model here, outside the canvas's drawing closure.
    let stalks = parameter == .velocity
      ? model.notes.map { note in
        (x: model.x(for: note.start), velocity: model.displayedVelocity(of: note),
         isSelected: model.selectedNoteIDs.contains(note.id), isOutside: note.start < .zero || note.start >= regionLength)
      }
      : []
    let points = parameter == .velocity ? [] : model.drawnControls.map { event in
      (x: model.x(for: event.position), value: event.value, isSelected: model.selectedControlIDs.contains(event.id))
    }
    let neutral: Int? = model.drawnKind?.neutralValue
    let endX = model.x(for: regionLength)

    Canvas { context, size in
      func y(_ value: Int) -> CGFloat { MIDIDrawLane.y(forValue: value, in: valueRange, height: size.height) }
      let offset = range.lowerBound

      // Faint guides at the top, middle and bottom of the range.
      var guides = Path()
      for value in [valueRange.lowerBound, (valueRange.lowerBound + valueRange.upperBound) / 2, valueRange.upperBound] {
        guides.addRect(CGRect(x: 0, y: y(value), width: size.width, height: 1))
      }
      context.fill(guides, with: .color(Color.white.opacity(0.05)))

      if parameter == .velocity {
        for stalk in stalks where stalk.x >= offset - 4 && stalk.x <= offset + size.width + 4 {
          let x = stalk.x - offset
          let top = y(stalk.velocity)
          let stalkColor = PianoRollModel.color(forVelocity: stalk.velocity).opacity(stalk.isOutside ? 0.35 : 1)
          context.fill(Path(CGRect(x: x, y: top, width: 2, height: size.height - MIDIDrawLane.inset - top)), with: .color(stalkColor))
          let head = Path(ellipseIn: CGRect(x: x - 2.5, y: top - 3.5, width: 7, height: 7))
          context.fill(head, with: .color(stalkColor))
          if stalk.isSelected {
            context.stroke(head, with: .color(.white), lineWidth: 1.5)
          }
        }
        return
      }

      guard !points.isEmpty || neutral != nil else { return }
      // Before the first point the controller sits at its neutral value (playback sets it so).
      let firstValue = neutral ?? points.first?.value ?? valueRange.lowerBound
      var line = Path()
      var area = Path()
      let startY = y(firstValue)
      line.move(to: CGPoint(x: -offset, y: startY))
      area.move(to: CGPoint(x: -offset, y: size.height))
      area.addLine(to: CGPoint(x: -offset, y: startY))
      var previousY = startY
      for point in points {
        let x = point.x - offset
        let pointY = y(point.value)
        line.addLine(to: CGPoint(x: x, y: previousY))
        line.addLine(to: CGPoint(x: x, y: pointY))
        area.addLine(to: CGPoint(x: x, y: previousY))
        area.addLine(to: CGPoint(x: x, y: pointY))
        previousY = pointY
      }
      let lastX = max(endX, points.last?.x ?? 0) - offset
      line.addLine(to: CGPoint(x: lastX, y: previousY))
      area.addLine(to: CGPoint(x: lastX, y: previousY))
      area.addLine(to: CGPoint(x: lastX, y: size.height))
      area.closeSubpath()
      context.fill(area, with: .color(color.opacity(0.16)))
      context.stroke(line, with: .color(color.opacity(points.isEmpty ? 0.35 : 0.95)), lineWidth: 1.5)

      // Points, unless they're packed too tightly to tell apart (a dense pitch bend).
      let visible = points.filter { $0.x >= offset - 6 && $0.x <= offset + size.width + 6 }
      let isDense = visible.count > Int(size.width / 5)
      for point in visible where !isDense || point.isSelected {
        let center = CGPoint(x: point.x - offset, y: y(point.value))
        let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        context.fill(dot, with: .color(point.isSelected ? .white : color))
        context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
      }
    }
    .frame(width: max(range.upperBound - range.lowerBound, 0), height: height)
    .offset(x: range.lowerBound)
    .allowsHitTesting(false)
  }
}

/// The lane's top edge, dragged to make the lane taller or shorter.
private struct LaneResizeEdge: View {
  let model: PianoRollModel

  @State private var startHeight: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Theme.separator)
      .frame(height: 1)
      .overlay {
        Color.clear
          .frame(height: 7)
          .contentShape(.rect)
          .pointerStyle(.rowResize)
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { drag in
                let start = startHeight ?? model.midiDrawHeight
                startHeight = start
                let range = PianoRollModel.midiDrawHeightRange
                model.midiDrawHeight = min(max(start - drag.translation.height, range.lowerBound), range.upperBound)
              }
              .onEnded { _ in
                startHeight = nil
                model.saveMIDIDrawHeight()
              })
      }
  }
}

/// The lane's left end, beside the keyboard: the parameter's name and its scale.
struct MIDIDrawScale: View {
  let model: PianoRollModel

  var body: some View {
    let parameter = model.midiDrawParameter
    let range = parameter.valueRange
    let height = model.midiDrawHeight
    ZStack(alignment: .topTrailing) {
      Rectangle().fill(Theme.header)
      ForEach([range.upperBound, (range.lowerBound + range.upperBound + 1) / 2, range.lowerBound], id: \.self) { value in
        Text(parameter.label(for: value == (range.lowerBound + range.upperBound + 1) / 2 && parameter == .control(.pitchBend) ? 0 : value))
          .font(Theme.monospaced(8))
          .foregroundStyle(Theme.tertiaryText)
          .offset(x: -4, y: MIDIDrawLane.y(forValue: value, in: range, height: height) - 5)
      }
    }
    .frame(width: PianoRollModel.Layout.keyboardWidth, height: height)
    .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
    .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    .accessibilityHidden(true)
  }
}
