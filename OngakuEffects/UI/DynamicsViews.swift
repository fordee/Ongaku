//
//  DynamicsViews.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)

// MARK: - Noise Gate

/// The Noise Gate: the level over the last few seconds against the threshold, whether the
/// gate is open, and its controls.
struct NoiseGateView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 720 × 340.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            HistoryGraph(input: meters?.inputHistory ?? [], reduction: meters?.reductionHistory ?? [],
              threshold: parameters.value("threshold"))
            VStack(spacing: 8) {
              let isOpen = (meters?.value(.gateOpen) ?? 0) >= 0.5
              Text(isOpen ? "OPEN" : "CLOSED")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isOpen ? .black : EffectStyle.label)
                .frame(width: 64, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOpen ? green : Color.black.opacity(0.5)))
                .accessibilityLabel(isOpen ? "Gate open" : "Gate closed")
              InOutMeters(meters: meters)
            }
          }
          .frame(height: 150)
          HStack(spacing: 0) {
            knob("threshold", "Threshold", "The level the sound must reach to open the gate. Set it just above the noise between notes.")
            knob("reduction", "Reduction", "How far the gate turns the sound down when it's closed. Less than all the way sounds more natural.")
            knob("hysteresis", "Hysteresis", "How far below the threshold the level must fall before the gate closes, so it doesn't chatter.")
            knob("attack", "Attack", "How quickly the gate opens. Very short keeps drum hits sharp; longer avoids clicks.")
            knob("hold", "Hold", "How long the gate stays open after the level drops, before it starts to close.")
            knob("release", "Release", "How long the gate takes to close. Longer lets notes ring out naturally.")
            knob("keyLowCut", "Key Low Cut", "Ignores lows when deciding whether to open, so rumble or a kick's spill doesn't open the gate.", tint: blue)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private func knob(_ identifier: String, _ name: String, _ help: String, tint: Color = orange) -> some View {
    HintKnob(parameter: parameters[identifier], name: name, help: help, hint: $hint, tint: tint)
  }
}

// MARK: - Transient Shaper

/// The Transient Shaper: a drum hit before (faint) and after (bright) its attack and
/// sustain are shaped, and its controls.
struct TransientShaperView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 660 × 340.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            HitPicture(attack: Double(parameters.value("attack")) / 100, sustain: Double(parameters.value("sustain")) / 100)
            InOutMeters(meters: meters)
          }
          .frame(height: 150)
          HStack(spacing: 0) {
            HintKnob(parameter: parameters["attack"], name: "Attack",
              help: "Turns the start of each hit up (punchier, snappier) or down (softer, further away).", hint: $hint, diameter: 64)
            HintKnob(parameter: parameters["sustain"], name: "Sustain",
              help: "Turns the ring after each hit up (more room and body) or down (tighter, drier).", hint: $hint, tint: blue, diameter: 64)
            HintKnob(parameter: parameters["output"], name: "Output", help: "The level out.", hint: $hint, tint: green)
            HintKnob(parameter: parameters["mix"], name: "Mix", help: "Blends the shaped sound with the original.", hint: $hint, tint: green)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

/// A hit's envelope: a sharp rise and a ring, with the attack and sustain applied.
private struct HitPicture: View {
  let attack: Double
  let sustain: Double

  var body: some View {
    let (attack, sustain) = (attack, sustain)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      func level(_ t: Double, shaped: Bool) -> Double {
        let hit = t < 0.02 ? t / 0.02 : exp(-(t - 0.02) / 0.18)
        guard shaped else { return hit }
        let attackGain = t < 0.06 ? pow(2, attack * 1.5 * (1 - t / 0.06)) : 1
        let sustainGain = t > 0.06 ? pow(2, sustain * 1.4 * min(1, (t - 0.06) / 0.2)) : 1
        return min(1.6, hit * attackGain * sustainGain)
      }
      func path(shaped: Bool) -> Path {
        var path = Path()
        for step in 0...200 {
          let t = Double(step) / 200 * 0.8
          let point = CGPoint(x: CGFloat(t / 0.8) * size.width, y: size.height - CGFloat(level(t, shaped: shaped) / 1.7) * size.height)
          if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
      }
      context.stroke(path(shaped: false), with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
      var filled = path(shaped: true)
      filled.addLine(to: CGPoint(x: size.width, y: size.height))
      filled.addLine(to: CGPoint(x: 0, y: size.height))
      filled.closeSubpath()
      context.fill(filled, with: .color(orange.opacity(0.18)))
      context.stroke(path(shaped: true), with: .color(orange), lineWidth: 2)
      context.draw(Text("ATTACK").font(.system(size: 8, weight: .bold)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: size.width * 0.05, y: 10), anchor: .leading)
      context.draw(Text("SUSTAIN").font(.system(size: 8, weight: .bold)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: size.width * 0.4, y: 10), anchor: .leading)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Hit shape")
  }
}

// MARK: - Maximizer

/// The Maximizer: loudness readouts (momentary, short-term, integrated, true peak), the
/// gain reduction over time, and its controls.
struct MaximizerView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 820 × 380.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            VStack(spacing: 8) {
              HStack(spacing: 8) {
                readout("Momentary", meters?.value(.momentary), "LUFS", help: "Loudness over the last 0.4 s.")
                readout("Short-Term", meters?.value(.shortTerm), "LUFS", help: "Loudness over the last 3 s.")
              }
              HStack(spacing: 8) {
                readout("Integrated", meters?.value(.integrated), "LUFS",
                  help: "Loudness of everything since you last reset it. Streaming services aim for about −14 LUFS.", isMain: true)
                readout("True Peak", meters?.value(.truePeak), "dBTP", help: "The highest peak, between samples too, since the reset.")
              }
              Button("Reset Loudness") { audioUnit.resetLoudness() }
                .controlSize(.small)
                .help("Starts the integrated loudness and true peak again: play the song from the top after this.")
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 4) {
              Text("Gain Reduction").font(.system(size: 9, weight: .medium)).foregroundStyle(EffectStyle.label)
              HistoryGraph(input: meters?.inputHistory ?? [], reduction: meters?.reductionHistory ?? [],
                threshold: parameters.value("ceiling"), tint: blue)
            }
            InOutMeters(meters: meters)
          }
          .frame(height: 190)
          HStack(spacing: 0) {
            HintKnob(parameter: parameters["gain"], name: "Gain",
              help: "Pushes the level up into the limiter: louder, with the peaks held under the ceiling.", hint: $hint, diameter: 60)
            HintKnob(parameter: parameters["ceiling"], name: "Ceiling",
              help: "The highest the output can go. −1 dB leaves room for MP3 and AAC encoding.", hint: $hint, tint: green)
            HintKnob(parameter: parameters["release"], name: "Release",
              help: "How quickly the gain comes back after a peak. Shorter is louder but can pump or distort.", hint: $hint, tint: blue)
            VStack(spacing: 8) {
              ParameterToggle(parameter: parameters["truePeak"], title: "True Peak",
                help: "Catches peaks that happen between samples, which can clip after conversion.", hint: $hint)
            }
            .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private func readout(_ title: String, _ value: Float?, _ unit: String, help: String, isMain: Bool = false) -> some View {
    VStack(spacing: 2) {
      Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(EffectStyle.label)
      Text(value.map { $0 > -100 ? String(format: "%.1f", $0) : "—" } ?? "—")
        .font(.system(size: isMain ? 26 : 20, weight: .semibold).monospacedDigit())
        .foregroundStyle(isMain ? orange : EffectStyle.value)
      Text(unit).font(.system(size: 8.5)).foregroundStyle(EffectStyle.label)
    }
    .frame(maxWidth: .infinity, minHeight: 66)
    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.4)))
    .help(help)
    .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - De-Esser

/// The De-Esser: the band it turns down (above the frequency, dipping as it works), the
/// reduction over time, and its controls.
struct DeEsserView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 700 × 340.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            SplitPicture(frequency: Double(parameters.value("frequency")), reduction: Double(meters?.reduction ?? 0))
            HistoryGraph(input: meters?.inputHistory ?? [], reduction: meters?.reductionHistory ?? [], tint: blue)
              .frame(width: 180)
            InOutMeters(meters: meters)
          }
          .frame(height: 150)
          HStack(spacing: 0) {
            HintKnob(parameter: parameters["frequency"], name: "Frequency",
              help: "Where the sibilance starts. Turn on Listen and sweep this until you hear only the \u{201C}ss\u{201D}.", hint: $hint, diameter: 58)
            HintKnob(parameter: parameters["threshold"], name: "Threshold",
              help: "How loud the sibilance must be before it's turned down. Lower catches more.", hint: $hint)
            HintKnob(parameter: parameters["range"], name: "Range", help: "The most it turns the sibilance down.", hint: $hint, tint: blue)
            ParameterToggle(parameter: parameters["listen"], title: "Listen",
              help: "Plays only what's being taken out, to find the frequency.", hint: $hint)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

/// The response: flat below the frequency, dipping above it by the reduction right now.
private struct SplitPicture: View {
  let frequency: Double
  let reduction: Double

  var body: some View {
    let (frequency, reduction) = (frequency, reduction)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      func x(_ f: Double) -> CGFloat { CGFloat(log(f / 20) / log(1_000)) * size.width }
      func y(_ decibels: Double) -> CGFloat { size.height * 0.3 - CGFloat(decibels / 30) * size.height * 0.7 }
      for f in [100.0, 1_000, 10_000] {
        context.stroke(Path { $0.move(to: CGPoint(x: x(f), y: 0)); $0.addLine(to: CGPoint(x: x(f), y: size.height)) },
          with: .color(EffectStyle.grid))
        context.draw(Text(f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))").font(.system(size: 8)).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: x(f) + 2, y: size.height - 3), anchor: .bottomLeading)
      }
      var path = Path()
      for step in 0...160 {
        let f = 20 * pow(1_000, Double(step) / 160)
        // The first-order split: the high band's share rises through the frequency.
        let high = (f / frequency) * (f / frequency) / (1 + (f / frequency) * (f / frequency))
        let gain = pow(10, reduction / 20)
        let magnitude = (1 - high) + high * gain
        let point = CGPoint(x: x(f), y: y(20 * log10(max(magnitude, 1e-3))))
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      context.stroke(path, with: .color(orange), lineWidth: 2)
      let marker = x(frequency)
      context.stroke(Path { $0.move(to: CGPoint(x: marker, y: 0)); $0.addLine(to: CGPoint(x: marker, y: size.height)) },
        with: .color(blue), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("De-esser band")
  }
}
