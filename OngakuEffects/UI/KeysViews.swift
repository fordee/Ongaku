//
//  KeysViews.swift
//  OngakuEffects
//

import SwiftUI

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)
private let purple = Color(red: 0.68, green: 0.45, blue: 0.98)
/// The Electric Piano's and Organ's cabinets: dark wood.
private let wood = LinearGradient(
  colors: [Color(red: 0.30, green: 0.18, blue: 0.11), Color(red: 0.20, green: 0.12, blue: 0.08)], startPoint: .top, endPoint: .bottom)

// MARK: - Electric Piano

/// The Electric Piano: its tone controls on a wooden panel, the tremolo and drive, and a
/// keyboard to play it.
struct ElectricPianoView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?

  var body: some View {
    // Laid out for 980 × 440.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      VStack(spacing: 12) {
        HStack(spacing: 0) {
          group("Tine") {
            HintKnob(parameter: parameters["tone"], name: "Tone",
              help: "How bright the tines are. Higher is more bite; lower is round and mellow.", hint: $hint)
            HintKnob(parameter: parameters["bell"], name: "Bell",
              help: "The bell-like ping at the start of a hard note.", hint: $hint)
            HintKnob(parameter: parameters["decay"], name: "Decay", help: "How long notes ring while you hold them.", hint: $hint, tint: purple)
            HintKnob(parameter: parameters["velocity"], name: "Velocity",
              help: "How much playing harder makes it louder and brighter.", hint: $hint, tint: purple)
          }
          group("Suitcase") {
            HintKnob(parameter: parameters["tremoloRate"], name: "Trem Rate", help: "How fast the tremolo pans between the speakers.", hint: $hint, tint: blue)
            HintKnob(parameter: parameters["tremoloDepth"], name: "Trem Depth",
              help: "How far it pans: the stereo tremolo of a Suitcase piano.", hint: $hint, tint: blue)
            HintKnob(parameter: parameters["drive"], name: "Drive", help: "The amp pushed: growl on the loud notes.", hint: $hint)
            HintKnob(parameter: parameters["volume"], name: "Volume", help: "The level out.", hint: $hint, tint: green)
          }
        }
        .padding(.vertical, 10)
        .background(wood, in: RoundedRectangle(cornerRadius: 8))
        PlayableKeyboard(lowestNote: 36, octaves: 5, accent: orange) { note, isDown in
          audioUnit.playNote(note, velocity: isDown ? 96 : 0)
        }
        .frame(height: 110)
      }
    }
  }

  private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(spacing: 6) {
      Text(title.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.5).foregroundStyle(Color(white: 0.85).opacity(0.7))
      HStack(spacing: 0) { content() }
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Organ

/// The Organ: nine drawbars (drag one down to pull it out), the percussion, vibrato and
/// rotary speaker with its horn spinning at the speed it's turning, and a keyboard.
struct OrganView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?
  @State private var rotor = RotorClock()

  var body: some View {
    // Laid out for 1080 × 500.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      VStack(spacing: 12) {
        HStack(alignment: .top, spacing: 16) {
          HStack(spacing: 6) {
            ForEach(0..<9, id: \.self) { bar in
              Drawbar(parameter: parameters["drawbar\(bar)"], footage: KeysParameters.footages[bar], kind: Drawbar.Kind(bar: bar), hint: $hint)
            }
          }
          .padding(10)
          .background(wood, in: RoundedRectangle(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
              ParameterToggle(parameter: parameters["percussion"], title: "Percussion",
                help: "A quick ping on the second or third harmonic when you strike a key with none held, as on a B3.", hint: $hint)
              ParameterPicker(parameter: parameters["percussionHarmonic"], options: ["2nd", "3rd"],
                help: "Which harmonic the percussion plays.", hint: $hint)
              ParameterPicker(parameter: parameters["percussionDecay"], options: ["Fast", "Slow"],
                help: "How quickly the percussion dies away.", hint: $hint)
            }
            HStack(spacing: 6) {
              Text("Vibrato").font(.system(size: 10, weight: .semibold)).foregroundStyle(EffectStyle.label)
              ParameterPicker(parameter: parameters["vibrato"], options: KeysParameters.vibratos,
                help: "The scanner: V1–V3 wobble the pitch, C1–C3 mix that with the steady sound for chorus.", hint: $hint)
            }
            HStack(spacing: 10) {
              TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                let _ = meters?.update()
                let angle = rotor.advance(to: timeline.date, rate: Double(meters?.value(.LFO) ?? 0.8),
                  isTurning: parameters.value("rotary") >= 0.5)
                RotaryHorn(angle: angle)
              }
              .frame(width: 64, height: 64)
              VStack(alignment: .leading, spacing: 4) {
                Text("Rotary").font(.system(size: 10, weight: .semibold)).foregroundStyle(EffectStyle.label)
                ParameterPicker(parameter: parameters["rotary"], options: KeysParameters.rotarySpeeds,
                  help: "The rotary speaker. Slow is chorale, fast is tremolo; it speeds up and slows down gradually. The mod wheel past halfway switches Slow to fast.",
                  hint: $hint)
              }
            }
            HStack(spacing: 0) {
              HintKnob(parameter: parameters["click"], name: "Key Click", help: "The click of the key contacts closing.", hint: $hint, diameter: 42)
              HintKnob(parameter: parameters["drive"], name: "Drive", help: "The preamp pushed: from warm to a full rock growl.", hint: $hint, diameter: 42)
              HintKnob(parameter: parameters["volume"], name: "Volume", help: "The level out.", hint: $hint, tint: green, diameter: 42)
            }
          }
        }
        PlayableKeyboard(lowestNote: 36, octaves: 5, accent: orange) { note, isDown in
          audioUnit.playNote(note, velocity: isDown ? 100 : 0)
        }
        .frame(height: 100)
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

/// One drawbar: drag down to pull it out (8 is all the way), up to push it in.
private struct Drawbar: View {
  enum Kind {
    /// 16′ and 5⅓′ (brown), the octaves (white), the rest (black), as on a Hammond.
    case sub, octave, other

    init(bar: Int) {
      switch bar {
      case 0, 1: self = .sub
      case 2, 3, 5, 8: self = .octave
      default: self = .other
      }
    }

    var color: Color {
      switch self {
      case .sub: Color(red: 0.45, green: 0.24, blue: 0.13)
      case .octave: Color(white: 0.93)
      case .other: Color(white: 0.08)
      }
    }

    var ink: Color { self == .octave ? .black : .white }
  }

  let parameter: ObservableAUParameter?
  let footage: String
  let kind: Kind
  @Binding var hint: String?

  @State private var dragStart: Float?

  private static let travel: CGFloat = 160

  var body: some View {
    let value = CGFloat(parameter?.value ?? 0)
    let help = "The \(footage) drawbar. Drag it down to pull it out (8 is all the way), up to push it in."
    VStack(spacing: 4) {
      Text("\(Int(value.rounded()))").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Color(white: 0.9))
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.45)).frame(width: 22, height: Self.travel + 30)
        VStack(spacing: 0) {
          // The rod, numbered as it comes out.
          ZStack(alignment: .top) {
            Rectangle().fill(kind.color.opacity(0.85))
            VStack(spacing: 0) {
              ForEach(1...8, id: \.self) { step in
                Text("\(step)").font(.system(size: 8, weight: .semibold)).foregroundStyle(kind.ink.opacity(0.7))
                  .frame(height: Self.travel / 8)
              }
            }
            .frame(height: Self.travel, alignment: .top)
          }
          // Pulled out by n steps shows 1 to n, as the real rods are printed.
          .frame(width: 18, height: max(0, value / 8 * Self.travel), alignment: .top)
          .clipped()
          // The handle.
          RoundedRectangle(cornerRadius: 4).fill(kind.color)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.5)))
            .overlay(Text(footage).font(.system(size: 8.5, weight: .bold)).foregroundStyle(kind.ink))
            .frame(width: 26, height: 26)
        }
      }
      .frame(height: Self.travel + 30, alignment: .top)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            guard let parameter else { return }
            if dragStart == nil { dragStart = parameter.value }
            let moved = Float(drag.translation.height / (Self.travel / 8))
            parameter.value = min(8, max(0, ((dragStart ?? 0) + moved).rounded()))
          }
          .onEnded { _ in dragStart = nil }
      )
    }
    .frame(width: 34)
    .help(help)
    .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
    .accessibilityElement()
    .accessibilityLabel("Drawbar \(footage)")
    .accessibilityValue("\(Int(value.rounded()))")
    .accessibilityAdjustableAction { direction in
      guard let parameter else { return }
      parameter.value = min(8, max(0, parameter.value + (direction == .increment ? 1 : -1)))
    }
  }
}

/// Turns the rotary horn picture at the speed the real one is turning.
@MainActor
final class RotorClock {
  private var angle = 0.0
  private var last: Date?

  func advance(to date: Date, rate: Double, isTurning: Bool) -> Double {
    defer { last = date }
    guard let last, isTurning else { return angle }
    angle = (angle + date.timeIntervalSince(last) * rate * 360).truncatingRemainder(dividingBy: 360)
    return angle
  }
}

/// The rotary speaker's horn seen from above: two bells on a spindle.
private struct RotaryHorn: View {
  let angle: Double

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)), with: .color(.black.opacity(0.5)))
      var rotated = context
      rotated.translateBy(x: center.x, y: center.y)
      rotated.rotate(by: .degrees(angle))
      let reach = size.width / 2 - 8
      rotated.fill(Path(roundedRect: CGRect(x: -reach, y: -3, width: reach * 2, height: 6), cornerRadius: 3), with: .color(Color(white: 0.6)))
      rotated.fill(Path(ellipseIn: CGRect(x: reach - 10, y: -8, width: 14, height: 16)), with: .color(orange))
      rotated.fill(Path(ellipseIn: CGRect(x: -reach - 4, y: -6, width: 10, height: 12)), with: .color(Color(white: 0.35)))
      context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(Color(white: 0.85)))
    }
    .accessibilityElement()
    .accessibilityLabel("Rotary speaker")
  }
}

#Preview("Electric Piano") {
  PluginPreview(effect: .electricPiano)
}

#Preview("Organ") {
  PluginPreview(effect: .organ, values: [.orgFirstDrawbar: 8, .orgLastDrawbar: 4])
}
