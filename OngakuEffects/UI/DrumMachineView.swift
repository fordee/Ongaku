//
//  DrumMachineView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Drum Machine: a grid of pads (click one to hear and edit it; they light up as
/// they're played), the selected pad's controls, and the kit's.
struct DrumMachineView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let tree: ObservableAUParameterGroup

  @State private var selected = 0
  @State private var hint: String?

  private static let accent = Color(red: 0.98, green: 0.42, blue: 0.32)

  private func p(_ identifier: String) -> ObservableAUParameter? {
    tree.children[identifier] as? ObservableAUParameter
  }

  private func padParameter(_ pad: Int, _ identifier: String) -> ObservableAUParameter? {
    (tree.children[DrumMachineParameters.pads[pad].identifier] as? ObservableAUParameterGroup)?.children[identifier]
      as? ObservableAUParameter
  }

  var body: some View {
    // Laid out for 980 × 560.
    VStack(spacing: 12) {
      header.frame(height: 40)
      HStack(alignment: .top, spacing: 12) {
        SynthSection(title: "Pads", accent: Self.accent) {
          padGrid
        }
        .frame(width: 560)
        SynthSection(title: DrumMachineParameters.pads[selected].name, accent: Self.color(of: selected)) {
          padEditor
        }
      }
      .frame(height: 420)
      hintLine.frame(height: 18)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(SynthBackground())
    .environment(\.colorScheme, .dark)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 0) {
        Text("DRUM MACHINE")
          .font(.system(size: 18, weight: .heavy))
          .tracking(3)
          .foregroundStyle(Synth.value)
        Text("ONGAKU")
          .font(.system(size: 8, weight: .bold))
          .tracking(4)
          .foregroundStyle(Self.accent)
      }
      Spacer()
      knob(p("drive"), "Drive", "Saturates the whole kit: warmer, then dirtier.", size: 30)
      knob(p("volume"), "Volume", "The kit's overall volume.", size: 30)
    }
  }

  // MARK: - Pads

  /// Pads are coloured by family: kicks, snares and claps, hats, toms, percussion, cymbals.
  static func color(of pad: Int) -> Color {
    switch DrumMachineParameters.pads[pad].identifier {
    case "kick": Color(red: 0.95, green: 0.33, blue: 0.3)
    case "snare", "clap", "rim": Color(red: 0.98, green: 0.6, blue: 0.22)
    case "closedHat", "openHat": Color(red: 0.95, green: 0.82, blue: 0.3)
    case "lowTom", "midTom", "highTom": Color(red: 0.42, green: 0.82, blue: 0.48)
    case "crash": Color(red: 0.7, green: 0.5, blue: 1.0)
    default: Color(red: 0.32, green: 0.66, blue: 1.0)
    }
  }

  private var padGrid: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
      let levels = (0..<DrumMachineParameters.pads.count).map {
        OngakuMeterValue(audioUnit.meters, OngakuMeter(rawValue: OngakuMeter.firstPad.rawValue + Int32($0)) ?? .firstPad)
      }
      Grid(horizontalSpacing: 10, verticalSpacing: 10) {
        ForEach(0..<3, id: \.self) { row in
          GridRow {
            ForEach(0..<4, id: \.self) { column in
              let pad = row * 4 + column
              PadButton(
                name: DrumMachineParameters.pads[pad].name, note: DrumMachineParameters.pads[pad].note,
                color: Self.color(of: pad), level: Double(levels[pad]), isSelected: selected == pad
              ) {
                selected = pad
                audioUnit.playNote(DrumMachineParameters.pads[pad].note, velocity: 110)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Pad editor

  private var padEditor: some View {
    let pad = DrumMachineParameters.pads[selected]
    let color = Self.color(of: selected)
    return VStack(alignment: .leading, spacing: 12) {
      DecayPicture(
        decay: Double(padParameter(selected, "decay")?.value ?? 100), tune: Double(padParameter(selected, "tune")?.value ?? 0),
        color: color)
        .frame(height: 96)
      HStack(alignment: .top, spacing: 4) {
        knob(padParameter(selected, "tune"), "Tune", "Tunes the drum up or down, in semitones.", color: color)
        knob(padParameter(selected, "decay"), "Decay", "How long the drum rings: shorter is tighter, longer is boomier.", color: color)
        knob(padParameter(selected, "tone"), pad.toneName, pad.toneHelp, color: color)
      }
      HStack(alignment: .top, spacing: 4) {
        knob(padParameter(selected, "level"), "Level", "How loud this drum is in the kit.", color: color)
        knob(padParameter(selected, "pan"), "Pan", "Where the drum sits, left to right.", color: color)
      }
      Spacer(minLength: 0)
      Text("Plays on \(Self.noteName(pad.note)) (General MIDI \(pad.note))")
        .font(.system(size: 10))
        .foregroundStyle(Synth.label)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Logic's octave numbering, as in Ongaku's Piano Roll: middle C (MIDI 60) is C3.
  static func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[note % 12])\(note / 12 - 2)"
  }

  // MARK: - Helpers

  @ViewBuilder
  private func knob(_ parameter: ObservableAUParameter?, _ label: String, _ help: String, color: Color? = nil, size: CGFloat = 46)
    -> some View
  {
    if let parameter {
      SynthKnob(parameter: parameter, label: label, accent: color ?? Self.accent, size: size)
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
    }
  }

  private var hintLine: some View {
    HStack(spacing: 6) {
      Image(systemName: hint == nil ? "lightbulb" : "info.circle").foregroundStyle(Self.accent)
      Text(hint ?? "Click a pad to hear it and shape it. The pads play the General MIDI drum notes, so drum parts from MIDI files play straight away. Double-click or Option-click a knob to reset it.")
        .foregroundStyle(hint == nil ? Synth.label : Synth.value)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
    }
    .font(.system(size: 11))
  }
}

/// A drum pad: rubbery and dark, glowing in its colour as it plays.
private struct PadButton: View {
  let name: String
  let note: Int
  let color: Color
  let level: Double
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 8)
          .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
        RoundedRectangle(cornerRadius: 8)
          .fill(color.opacity(0.15 + 0.7 * level))
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? color : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(name.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Synth.value)
          Text(DrumMachineView.noteName(note))
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(Synth.label)
        }
        .padding(10)
      }
      .shadow(color: color.opacity(0.6 * level), radius: 10)
      .frame(width: 124, height: 118)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// How the selected drum dies away (its length from Decay), with its pitch from Tune
/// drawn as the wave's spacing.
private struct DecayPicture: View {
  let decay: Double
  let tune: Double
  let color: Color

  var body: some View {
    let (decay, tune, color) = (decay, tune, color)
    SynthScreen {
      Canvas { context, size in
        let cycles = 9 * pow(2, tune / 12)
        let length = min(1, decay / 300 + 0.1)
        var path = Path()
        for step in 0...300 {
          let t = Double(step) / 300
          let envelope = exp(-t / (length * 0.35))
          let value = sin(2 * .pi * cycles * t) * envelope
          let point = CGPoint(x: CGFloat(t) * size.width, y: size.height / 2 - CGFloat(value) * size.height * 0.4)
          if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        glow(path, color, in: context)
      }
    }
  }
}
