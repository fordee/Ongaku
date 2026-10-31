//
//  MIDIEffectEditor.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// A MIDI effect's settings, in a popover from its slot. Each change is one undoable step
/// (a slider's when it's let go) and is heard straight away.
struct MIDIEffectEditor: View {
  let model: ProjectWindowModel
  let trackID: Track.ID
  let effect: MIDIEffect

  /// The settings as they're being changed (sliders change them before they're committed).
  @State private var draft: MIDIEffect.Settings?

  private var settings: MIDIEffect.Settings { draft ?? effect.settings }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(effect.name).font(Theme.font(13, weight: .semibold))
        Spacer()
        Toggle("On", isOn: Binding(
          get: { !effect.isBypassed },
          set: { isOn in
            var changed = effect
            changed.isBypassed = !isOn
            model.perform(UpdateMIDIEffect(changed, in: trackID, actionName: isOn ? "Turn On MIDI Effect" : "Bypass MIDI Effect"))
          }))
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      Text(summary)
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      controls
    }
    .padding(14)
    .frame(width: 300)
    .onChange(of: effect.settings) { draft = nil }
  }

  private var summary: String {
    switch settings {
    case .arpeggiator: "Plays held chords as a pattern of single notes, in time with the song."
    case .chordTrigger: "Plays a whole chord from each note."
    case .scaleQuantize: "Moves every note to the nearest note of a scale, so nothing is out of key."
    case .noteRepeater: "Repeats each note like an echo, fading or climbing as it goes."
    case .transposer: "Shifts every note up or down."
    case .velocityProcessor: "Makes notes louder or softer, keeps them within a range, or fixes them at one velocity."
    case .randomizer: "Changes notes a little at random so a part sounds less mechanical (the same way each time it plays)."
    }
  }

  @ViewBuilder
  private var controls: some View {
    switch settings {
    case .arpeggiator(let arp):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Rate") { divisionPicker(arp.rate) { var a = arp; a.rate = $0; commit(.arpeggiator(a)) } }
        row("Order") {
          Picker("", selection: Binding(get: { arp.order }, set: { var a = arp; a.order = $0; commit(.arpeggiator(a)) })) {
            ForEach(Arpeggiator.Order.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
        }
        row("Octaves") {
          Stepper("\(arp.octaves)", value: Binding(get: { arp.octaves }, set: { var a = arp; a.octaves = $0; commit(.arpeggiator(a)) }), in: 1...4)
        }
        row("Gate") {
          slider(arp.gate * 100, in: 5...100, label: "\(Int(arp.gate * 100)) %") { value, done in
            var a = arp
            a.gate = value / 100
            done ? commit(.arpeggiator(a)) : preview(.arpeggiator(a))
          }
        }
        row("Velocity") {
          velocityChoice(arp.fixedVelocity) { var a = arp; a.fixedVelocity = $0; commit(.arpeggiator(a)) }
        }
      }
    case .chordTrigger(let trigger):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Chord") {
          Picker("", selection: Binding(get: { trigger.chord }, set: { commit(.chordTrigger(ChordTrigger(chord: $0))) })) {
            ForEach(ChordTrigger.Chord.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
        }
      }
    case .scaleQuantize(let quantize):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Root") {
          Picker("", selection: Binding(get: { quantize.root }, set: { var q = quantize; q.root = $0; commit(.scaleQuantize(q)) })) {
            ForEach(0..<12, id: \.self) { Text(Self.pitchNames[$0]).tag($0) }
          }
          .labelsHidden()
        }
        row("Scale") {
          Picker("", selection: Binding(get: { quantize.scale }, set: { var q = quantize; q.scale = $0; commit(.scaleQuantize(q)) })) {
            ForEach(ScaleQuantize.Scale.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
        }
      }
    case .noteRepeater(let repeater):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Rate") { divisionPicker(repeater.rate) { var r = repeater; r.rate = $0; commit(.noteRepeater(r)) } }
        row("Repeats") {
          Stepper("\(repeater.repeats)", value: Binding(get: { repeater.repeats }, set: { var r = repeater; r.repeats = $0; commit(.noteRepeater(r)) }), in: 1...16)
        }
        row("Velocity") {
          slider(repeater.velocityChange, in: -100...100, label: String(format: "%+.0f %%", repeater.velocityChange)) { value, done in
            var r = repeater
            r.velocityChange = value.rounded()
            done ? commit(.noteRepeater(r)) : preview(.noteRepeater(r))
          }
        }
        row("Transpose") {
          Stepper(String(format: "%+d st", repeater.transpose), value: Binding(
            get: { repeater.transpose }, set: { var r = repeater; r.transpose = $0; commit(.noteRepeater(r)) }), in: -12...12)
        }
      }
    case .transposer(let transposer):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Transpose") {
          Stepper(String(format: "%+d semitones", transposer.semitones), value: Binding(
            get: { transposer.semitones }, set: { commit(.transposer(Transposer(semitones: $0))) }), in: -48...48)
        }
      }
    case .velocityProcessor(let processor):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Fixed") {
          velocityChoice(processor.fixed) { var p = processor; p.fixed = $0; commit(.velocityProcessor(p)) }
        }
        row("Scale") {
          slider(processor.scale, in: 0...200, label: "\(Int(processor.scale)) %") { value, done in
            var p = processor
            p.scale = value.rounded()
            done ? commit(.velocityProcessor(p)) : preview(.velocityProcessor(p))
          }
        }
        row("Offset") {
          Stepper(String(format: "%+d", processor.offset), value: Binding(
            get: { processor.offset }, set: { var p = processor; p.offset = $0; commit(.velocityProcessor(p)) }), in: -127...127, step: 5)
        }
        row("Range") {
          HStack(spacing: 4) {
            Stepper("\(processor.minimum)", value: Binding(
              get: { processor.minimum }, set: { var p = processor; p.minimum = $0; commit(.velocityProcessor(p)) }), in: 1...processor.maximum, step: 5)
            Text("to").foregroundStyle(Theme.secondaryText)
            Stepper("\(processor.maximum)", value: Binding(
              get: { processor.maximum }, set: { var p = processor; p.maximum = $0; commit(.velocityProcessor(p)) }), in: processor.minimum...127, step: 5)
          }
        }
      }
    case .randomizer(let randomizer):
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Velocity") {
          slider(Double(randomizer.velocity), in: 0...64, label: "± \(randomizer.velocity)") { value, done in
            var r = randomizer
            r.velocity = Int(value.rounded())
            done ? commit(.randomizer(r)) : preview(.randomizer(r))
          }
        }
        row("Timing") {
          slider(Double(randomizer.timing), in: 0...120, label: "± \(randomizer.timing) ticks") { value, done in
            var r = randomizer
            r.timing = Int(value.rounded())
            done ? commit(.randomizer(r)) : preview(.randomizer(r))
          }
        }
        row("Pitch") {
          Stepper("± \(randomizer.pitch) st", value: Binding(
            get: { randomizer.pitch }, set: { var r = randomizer; r.pitch = $0; commit(.randomizer(r)) }), in: 0...12)
        }
        row("How Often") {
          slider(randomizer.pitchChance, in: 0...100, label: "\(Int(randomizer.pitchChance)) %") { value, done in
            var r = randomizer
            r.pitchChance = value.rounded()
            done ? commit(.randomizer(r)) : preview(.randomizer(r))
          }
        }
        row("") {
          Button("New Random Pattern") { var r = randomizer; r.seed = UInt64.random(in: 0...UInt64.max); commit(.randomizer(r)) }
            .controlSize(.small)
        }
      }
    }
  }

  private static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

  private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    GridRow {
      Text(title).font(Theme.font(11)).foregroundStyle(Theme.secondaryText).gridColumnAlignment(.trailing)
      content().font(Theme.font(11))
    }
  }

  private func divisionPicker(_ value: NoteDivision, set: @escaping (NoteDivision) -> Void) -> some View {
    Picker("", selection: Binding(get: { value }, set: set)) {
      ForEach(NoteDivision.allCases) { Text($0.title).tag($0) }
    }
    .labelsHidden()
  }

  /// "As Played", or a fixed velocity.
  private func velocityChoice(_ value: Int?, set: @escaping (Int?) -> Void) -> some View {
    HStack(spacing: 6) {
      Toggle("Fixed", isOn: Binding(get: { value != nil }, set: { set($0 ? 100 : nil) }))
        .toggleStyle(.checkbox)
      if let value {
        Stepper("\(value)", value: Binding(get: { value }, set: { set($0) }), in: 1...127, step: 5)
      } else {
        Text("As played").foregroundStyle(Theme.secondaryText)
      }
    }
  }

  /// A slider that shows its value as it moves and commits when let go.
  private func slider(_ value: Double, in range: ClosedRange<Double>, label: String, change: @escaping (Double, Bool) -> Void)
    -> some View
  {
    HStack(spacing: 6) {
      Slider(value: Binding(get: { value }, set: { change($0, false) }), in: range) { editing in
        if !editing { change(value, true) }
      }
      .frame(width: 130)
      Text(label).font(Theme.monospaced(10)).frame(width: 70, alignment: .trailing)
    }
  }

  private func preview(_ settings: MIDIEffect.Settings) {
    draft = settings
  }

  private func commit(_ settings: MIDIEffect.Settings) {
    draft = nil
    guard settings != effect.settings else { return }
    var changed = effect
    changed.settings = settings
    model.perform(UpdateMIDIEffect(changed, in: trackID))
  }
}

#Preview("Arpeggiator") {
  let arpeggiator = MIDIEffect(.arpeggiator(Arpeggiator(rate: .sixteenth, order: .upDown, octaves: 2)))
  var keys = Track(name: "Keys", kind: .softwareInstrument)
  keys.channel.midiEffects = [arpeggiator]
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
  return MIDIEffectEditor(model: model, trackID: keys.id, effect: arpeggiator)
}
