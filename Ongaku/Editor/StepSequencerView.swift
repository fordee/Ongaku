//
//  StepSequencerView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Step Sequencer: the open pattern region's rows (a drum or a note each) as rows of
/// steps. Click a step to turn it on or off, or drag across steps to paint them; the edit
/// mode chooses what painting changes (velocity, gate, chance, repeats), drawn as each
/// step's height. Each row's menu sets its own length, rate and direction.
struct StepSequencerView: View {
  let model: PianoRollModel
  let region: Region

  static let rowHeight: CGFloat = 30
  static let nameWidth: CGFloat = 150

  var body: some View {
    if let pattern = region.pattern {
      VStack(spacing: 0) {
        StepSequencerBar(model: model, pattern: pattern)
        ScrollView([.horizontal, .vertical]) {
          VStack(spacing: 0) {
            ForEach(pattern.rows) { row in
              StepRow(model: model, pattern: pattern, row: row)
            }
            AddRowButton(model: model)
          }
        }
      }
      .background(Theme.lanes)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Step Sequencer")
    }
  }
}

/// The pattern's settings and the edit mode.
private struct StepSequencerBar: View {
  let model: PianoRollModel
  let pattern: StepPattern

  @State private var swing: Double?

  var body: some View {
    HStack(spacing: 14) {
      Picker("Edit", selection: Binding(get: { model.stepEditMode }, set: { model.stepEditMode = $0 })) {
        ForEach(StepEditMode.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .help("What clicking and dragging on steps changes")
      Divider().frame(height: 16)
      Stepper("Steps: \(pattern.length)", value: Binding(get: { pattern.length }, set: { model.setPatternLength($0) }),
        in: StepPattern.lengthRange)
        .fixedSize()
        .help("How many steps the pattern has before it starts again")
      Picker("Rate", selection: Binding(get: { pattern.rate }, set: { model.setPatternRate($0) })) {
        ForEach(NoteDivision.allCases) { Text($0.title).tag($0) }
      }
      .fixedSize()
      .help("How long each step is")
      HStack(spacing: 6) {
        Text("Swing").foregroundStyle(Theme.secondaryText)
        Slider(value: Binding(get: { swing ?? pattern.swing }, set: { swing = $0 }), in: 0...1) { editing in
          if !editing, let swing {
            model.setSwing(swing)
            self.swing = nil
          }
        }
        .frame(width: 90)
        Text("\(Int((swing ?? pattern.swing) * 100)) %").font(Theme.monospaced(10)).frame(width: 34, alignment: .trailing)
      }
      .help("Delays every second step, for a shuffle")
      Spacer()
      Button("Convert to MIDI Region") { model.convertPatternToNotes() }
        .help("Turn the pattern into the notes it plays, to edit them in the Piano Roll")
    }
    .font(Theme.font(11))
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(Theme.panel)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }
}

/// One row: its name, mute and menu, then its steps.
private struct StepRow: View {
  let model: PianoRollModel
  let pattern: StepPattern
  let row: StepPattern.Row

  /// While a click or drag paints the row: each touched step's new value (0 to 1).
  @State private var painted: [Int: Double] = [:]

  private static let stepWidth: CGFloat = 26

  var body: some View {
    let length = pattern.length(of: row)
    HStack(spacing: 0) {
      header
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          let mode = model.stepEditMode
          for index in 0..<length {
            let rect = CGRect(x: CGFloat(index) * Self.stepWidth + 2, y: 3, width: Self.stepWidth - 4, height: size.height - 6)
            // Each beat's steps a shade lighter, as in Logic.
            let isBeatGroup = (index / 4) % 2 == 0
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(isBeatGroup ? Theme.raised : Theme.panel))
            guard row.steps.indices.contains(index) else { continue }
            let step = row.steps[index]
            let fraction = painted[index] ?? (step.isOn ? mode.fraction(of: step) : 0)
            let isOn = painted[index].map { mode == .on ? $0 >= 0.5 : true } ?? step.isOn
            guard isOn else { continue }
            let barHeight = mode == .on ? rect.height : max(3, rect.height * fraction)
            let bar = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
            let velocity = Double(step.velocity) / 127
            context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(
              (row.isMuted ? Theme.secondaryText : Theme.accent).opacity(0.45 + 0.55 * velocity)))
            if step.chance < 100 {
              context.draw(Text("?").font(Theme.font(9, weight: .bold)).foregroundStyle(Color.black.opacity(0.7)),
                at: CGPoint(x: rect.midX, y: rect.midY))
            } else if step.repeats > 1 {
              context.draw(Text("×\(step.repeats)").font(Theme.font(8, weight: .bold)).foregroundStyle(Color.black.opacity(0.7)),
                at: CGPoint(x: rect.midX, y: rect.midY))
            }
          }
        }
        StepPlayhead(model: model, row: row, stepWidth: Self.stepWidth)
      }
      .frame(width: CGFloat(length) * Self.stepWidth, height: StepSequencerView.rowHeight)
      .contentShape(.rect)
      .gesture(paint(length: length))
      Spacer(minLength: 0)
    }
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    .opacity(row.isMuted ? 0.6 : 1)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(row.name) row")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("step-row")
  }

  private var header: some View {
    HStack(spacing: 6) {
      Button {
        model.toggleRowMute(row.id)
      } label: {
        Text("M").font(Theme.font(9, weight: .bold))
      }
      .buttonStyle(ThemeButtonStyle(isOn: row.isMuted, onColor: Theme.mute, width: 18, height: 16))
      .help(row.isMuted ? "Unmute the row" : "Mute the row")
      .accessibilityLabel("Mute \(row.name)")
      Menu {
        Menu("Length") {
          Button(row.length == nil ? "✓ Pattern (\(pattern.length))" : "Pattern (\(pattern.length))") { model.setRowLength(nil, of: row.id) }
          ForEach([3, 4, 5, 6, 7, 8, 12, 16, 24, 32], id: \.self) { steps in
            Button(row.length == steps ? "✓ \(steps) Steps" : "\(steps) Steps") { model.setRowLength(steps, of: row.id) }
          }
        }
        Menu("Rate") {
          Button(row.rate == nil ? "✓ Pattern (\(pattern.rate.title))" : "Pattern (\(pattern.rate.title))") { model.setRowRate(nil, of: row.id) }
          ForEach(NoteDivision.allCases) { rate in
            Button(row.rate == rate ? "✓ \(rate.title)" : rate.title) { model.setRowRate(rate, of: row.id) }
          }
        }
        Menu("Direction") {
          ForEach(StepPattern.Row.Direction.allCases) { direction in
            Button(row.direction == direction ? "✓ \(direction.title)" : direction.title) { model.setRowDirection(direction, of: row.id) }
          }
        }
        Divider()
        Button("Clear Row") { model.clearRow(row.id) }
        Button("Remove Row", role: .destructive) { model.removeRow(row.id) }
      } label: {
        HStack(spacing: 4) {
          Text(row.name).font(Theme.font(11, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
          if row.length != nil || row.rate != nil || row.direction != .forward {
            Text(rowSummary).font(Theme.font(9)).foregroundStyle(Theme.secondaryText).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .help("Click for the row's length, rate and direction")
    }
    .padding(.horizontal, 8)
    .frame(width: StepSequencerView.nameWidth, height: StepSequencerView.rowHeight)
    .background(Theme.panel)
    .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
  }

  private var rowSummary: String {
    [row.length.map { "\($0)" }, row.rate?.title, row.direction == .forward ? nil : row.direction.title]
      .compactMap { $0 }.joined(separator: " · ")
  }

  /// Clicking or dragging: in Step On/Off, every step touched becomes the opposite of the
  /// first one; otherwise each takes the value at the pointer's height.
  private func paint(length: Int) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { drag in
        let step = Int(drag.location.x / Self.stepWidth)
        guard (0..<length).contains(step) else { return }
        if model.stepEditMode == .on {
          if painted.isEmpty {
            let isOn = row.steps.indices.contains(step) && row.steps[step].isOn
            painted[step] = isOn ? 0 : 1
          } else if painted[step] == nil, let value = painted.values.first {
            painted[step] = value
          }
        } else {
          let fraction = 1 - Double((drag.location.y - 3) / (StepSequencerView.rowHeight - 6))
          painted[step] = min(max(fraction, 0), 1)
        }
      }
      .onEnded { _ in
        model.setSteps(painted, inRow: row.id)
        painted = [:]
      }
  }

  private var accessibilityValue: String {
    let on = row.steps.indices.filter { row.steps[$0].isOn }.map { "\($0 + 1)" }
    return on.isEmpty ? "Empty" : "Steps \(on.joined(separator: ", "))"
  }
}

/// The step a row is playing, lit while the song plays.
private struct StepPlayhead: View {
  let model: PianoRollModel
  let row: StepPattern.Row
  let stepWidth: CGFloat

  var body: some View {
    if model.window.engine.isPlaying, let step = model.currentStep(of: row) {
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
        .frame(width: stepWidth - 4, height: StepSequencerView.rowHeight - 6)
        .offset(x: CGFloat(step) * stepWidth + 2, y: 3)
        .allowsHitTesting(false)
    }
  }
}

/// Adds a row for a note: a drum of the kit, or any pitch.
private struct AddRowButton: View {
  let model: PianoRollModel

  var body: some View {
    HStack {
      Menu("Add Row") {
        Menu("Drums") {
          ForEach(StepPattern.drumRows + [(44, "Pedal Hat"), (37, "Side Stick"), (56, "Cowbell"), (70, "Shaker")], id: \.pitch) { drum in
            Button(drum.name) { model.addRow(pitch: drum.pitch, name: drum.name) }
          }
        }
        Menu("Notes") {
          ForEach((2...6).reversed(), id: \.self) { octave in
            Menu("C\(octave - 2)–B\(octave - 2)") {
              ForEach((0..<12).reversed(), id: \.self) { step in
                let pitch = octave * 12 + step
                Button(PianoRollModel.noteName(pitch)) { model.addRow(pitch: pitch, name: PianoRollModel.noteName(pitch)) }
              }
            }
          }
        }
      }
      .fixedSize()
      .controlSize(.small)
      Spacer()
    }
    .padding(8)
  }
}
