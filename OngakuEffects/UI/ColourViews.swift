//
//  ColourViews.swift
//  OngakuEffects
//

import AppKit
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)
private let purple = Color(red: 0.68, green: 0.45, blue: 0.98)

// MARK: - Saturation

/// Saturation: its curve for the type and drive (level-matched, so the slope shows the
/// colour rather than the gain), and its controls.
struct SaturationView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 720 × 360.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        HStack(alignment: .top, spacing: 16) {
          CurvePicture(drive: pow(10, parameters.value("drive") / 20), type: Int32(parameters.value("type").rounded()))
            .frame(width: 210, height: 210)
          VStack(spacing: 14) {
            ParameterPicker(parameter: parameters["type"], options: SaturationParameters.types,
              help: "Tape: soft and warm, with a little low bump. Tube: rounder, richer in even harmonics. Transistor: harder and grittier.",
              hint: $hint)
            HStack(spacing: 0) {
              HintKnob(parameter: parameters["drive"], name: "Drive",
                help: "How hard the sound is pushed into the curve: more is warmer, then dirtier. The level stays about the same.",
                hint: $hint, diameter: 64)
              HintKnob(parameter: parameters["tone"], name: "Tone", help: "Darker to the left, brighter to the right.", hint: $hint, tint: blue)
            }
            HStack(spacing: 0) {
              HintKnob(parameter: parameters["output"], name: "Output", help: "The level out.", hint: $hint, tint: green)
              HintKnob(parameter: parameters["mix"], name: "Mix", help: "Blends the saturated sound with the clean one.", hint: $hint, tint: green)
            }
          }
          InOutMeters(meters: meters)
            .frame(height: 210)
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

private struct CurvePicture: View {
  let drive: Float
  let type: Int32

  var body: some View {
    let (drive, type) = (drive, type)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      func point(_ x: Float, _ y: Float) -> CGPoint {
        CGPoint(x: CGFloat((x + 1) / 2) * size.width, y: size.height - CGFloat((max(-1.2, min(1.2, y)) + 1) / 2) * size.height)
      }
      for line: Float in [-0.5, 0, 0.5] {
        context.stroke(Path { $0.move(to: point(line, -1)); $0.addLine(to: point(line, 1)) }, with: .color(EffectStyle.grid))
        context.stroke(Path { $0.move(to: point(-1, line)); $0.addLine(to: point(1, line)) }, with: .color(EffectStyle.grid))
      }
      context.stroke(Path { $0.move(to: point(-1, -1)); $0.addLine(to: point(1, 1)) },
        with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      var curve = Path()
      for step in 0...160 {
        let x = Float(step) / 80 - 1
        let y = OngakuSaturationCurve(x, drive, type)
        if step == 0 { curve.move(to: point(x, y)) } else { curve.addLine(to: point(x, y)) }
      }
      context.stroke(curve, with: .color(orange), lineWidth: 2)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Saturation curve")
  }
}

// MARK: - Doubler

/// The Doubler: the original in the middle and its two copies either side, as far out as
/// the width and as far back as their delays, and its controls.
struct DoublerView: View {
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
            StagePicture(
              width: Double(parameters.value("width")) / 100, delay: Double(parameters.value("delay")),
              detune: Double(parameters.value("detune")), mix: Double(parameters.value("mix")) / 100)
            InOutMeters(meters: meters)
          }
          .frame(height: 150)
          HStack(spacing: 0) {
            HintKnob(parameter: parameters["delay"], name: "Delay",
              help: "How far behind the copies are. 10–30 ms sounds like a second take; less is tighter.", hint: $hint)
            HintKnob(parameter: parameters["detune"], name: "Detune",
              help: "How out of tune the copies are (one sharp, one flat). A little makes it thick; a lot sounds like chorus.", hint: $hint)
            HintKnob(parameter: parameters["drift"], name: "Drift",
              help: "How much the timing and tuning wander, as a real second player's would.", hint: $hint, tint: purple)
            HintKnob(parameter: parameters["width"], name: "Width", help: "How far left and right the copies sit.", hint: $hint, tint: blue)
            HintKnob(parameter: parameters["mix"], name: "Mix", help: "How loud the copies are against the original.", hint: $hint, tint: green)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

private struct StagePicture: View {
  let width: Double
  let delay: Double
  let detune: Double
  let mix: Double

  var body: some View {
    let (width, delay, detune, mix) = (width, delay, detune, mix)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      for (text, x) in [("L", CGFloat(10)), ("R", size.width - 10)] {
        context.draw(Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(EffectStyle.label), at: CGPoint(x: x, y: 10))
      }
      func player(_ x: CGFloat, _ depth: CGFloat, _ color: Color, _ label: String, _ alpha: Double) {
        let radius = 16 - depth * 6
        let center = CGPoint(x: x, y: size.height * (0.45 + depth * 0.25))
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
          with: .color(color.opacity(alpha)))
        context.draw(Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: center.x, y: center.y + radius + 9))
      }
      let half = size.width / 2
      let depth = CGFloat(min(1, delay / 60))
      let copyAlpha = 0.3 + 0.7 * mix
      player(half - CGFloat(width) * (half - 40), depth, blue, String(format: "+%.0f ct", detune), copyAlpha)
      player(half + CGFloat(width) * (half - 40), min(1, depth * 1.37), purple, String(format: "−%.0f ct", detune), copyAlpha)
      player(half, 0, orange, "Original", 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Doubler stage")
  }
}

// MARK: - Convolution Reverb

/// The Convolution Reverb: its impulse response (synthesized from the room's shape, or
/// loaded from a file), and its controls.
struct ConvolutionReverbView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?
  @State private var isTargeted = false

  private var display: SamplerDisplay { audioUnit.impulseDisplay }

  var body: some View {
    // Laid out for 900 × 380.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(display.name.map { "Impulse Response: \($0) (\(String(format: "%.1f", display.duration)) s)" }
                  ?? "Synthesized from Decay, Size and Damping")
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(EffectStyle.label)
                Spacer()
                Button("Load Impulse Response…", action: chooseFile)
                  .controlSize(.small)
                  .help("Use the reverb of a real space: a recording of a click or sweep in it (WAV or AIFF). Or drop one on the picture.")
                if display.name != nil {
                  Button("Use Synthesized") { audioUnit.setLoadedImpulse(nil) }
                    .controlSize(.small)
                }
              }
              ImpulsePicture(
                overview: display.overview,
                decay: Double(parameters.value("decay")), size: Double(parameters.value("size")) / 100,
                damping: Double(parameters.value("damping")) / 100, predelay: Double(parameters.value("predelay")))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(blue, lineWidth: isTargeted ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                  guard let url = urls.first else { return false }
                  audioUnit.loadImpulse(from: url)
                  return true
                } isTargeted: { isTargeted = $0 }
              // Why a file didn't load, or what was left out of one that did.
              if let message = display.error ?? display.notice {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
              }
            }
            InOutMeters(meters: meters)
          }
          .frame(height: 170)
          HStack(spacing: 0) {
            knob("predelay", "Predelay", "The gap before the reverb starts, keeping the dry sound clear.")
            knob("decay", "Decay", "How long the reverb takes to die away (synthesized responses).", isShaping: true)
            knob("size", "Size", "How big the space is: how far apart its first reflections are.", isShaping: true)
            knob("damping", "Damping", "How fast the highs die away: soft rooms are damped, bare stone ones aren't.", isShaping: true)
            knob("width", "Width", "How wide the reverb spreads. 0 % is mono.", tint: blue)
            knob("lowCut", "Low Cut", "Thins the reverb so it doesn't muddy the bass.", tint: blue)
            knob("highCut", "High Cut", "Darkens the reverb.", tint: blue)
            knob("mix", "Mix", "How much reverb against the dry sound. Use 100 % on an aux send.", tint: green)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private func knob(_ identifier: String, _ name: String, _ help: String, tint: Color = orange, isShaping: Bool = false)
    -> some View
  {
    HintKnob(parameter: parameters[identifier], name: name, help: help, hint: $hint, tint: tint, diameter: 46)
      .opacity(isShaping && display.name != nil ? 0.4 : 1)
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.message = "Choose an impulse response for the reverb."
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { audioUnit.loadImpulse(from: url) }
    }
  }
}

/// The impulse response: a loaded file's waveform, or the synthesized one's decay (its
/// early reflections, then the tail, the highs falling away faster as damping rises).
private struct ImpulsePicture: View {
  let overview: [Float]
  let decay: Double
  let size: Double
  let damping: Double
  let predelay: Double

  var body: some View {
    let (overview, decay, roomSize, damping, predelay) = (overview, decay, size, damping, predelay)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      let middle = size.height / 2
      if !overview.isEmpty {
        var wave = Path()
        let barWidth = size.width / CGFloat(overview.count)
        for (index, peak) in overview.enumerated() {
          let height = max(0.5, CGFloat(peak) * (middle - 4))
          wave.addRect(CGRect(x: CGFloat(index) * barWidth, y: middle - height, width: max(1, barWidth * 0.8), height: height * 2))
        }
        context.fill(wave, with: .color(blue.opacity(0.85)))
        return
      }
      let length = predelay / 1000 + decay * 1.15
      func x(_ t: Double) -> CGFloat { CGFloat(t / length) * size.width }
      // The tail, and (fainter) its highs.
      for (color, extra) in [(blue, 0.0), (purple, damping * 7)] {
        var envelope = Path()
        envelope.move(to: CGPoint(x: x(predelay / 1000), y: middle))
        for step in 0...200 {
          let t = Double(step) / 200 * decay * 1.15
          let level = exp(-6.9 * t / decay) * exp2(-t / decay * extra * 0.4) * min(1, t / (0.004 + roomSize * 0.05))
          envelope.addLine(to: CGPoint(x: x(predelay / 1000 + t), y: middle - CGFloat(level) * (middle - 6)))
        }
        for step in stride(from: 200, through: 0, by: -1) {
          let t = Double(step) / 200 * decay * 1.15
          let level = exp(-6.9 * t / decay) * exp2(-t / decay * extra * 0.4) * min(1, t / (0.004 + roomSize * 0.05))
          envelope.addLine(to: CGPoint(x: x(predelay / 1000 + t), y: middle + CGFloat(level) * (middle - 6)))
        }
        envelope.closeSubpath()
        context.fill(envelope, with: .color(color.opacity(extra == 0 ? 0.35 : 0.4)))
      }
      // The early reflections, as lines.
      let count = 6 + Int(roomSize * 10)
      for k in 0..<count {
        let t = predelay / 1000 + 0.002 + (0.005 + roomSize * 0.065) * (Double(k) + 0.5) / Double(count)
        let height = (middle - 6) * CGFloat(exp(-Double(k) / Double(count) * 1.5))
        context.stroke(Path { $0.move(to: CGPoint(x: x(t), y: middle - height)); $0.addLine(to: CGPoint(x: x(t), y: middle + height)) },
          with: .color(orange.opacity(0.8)), lineWidth: 1.2)
      }
      context.draw(Text(String(format: "%.1f s", length)).font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: size.width - 4, y: size.height - 4), anchor: .bottomTrailing)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Impulse response")
  }
}

// MARK: - Vocal Strip

/// The Vocal Strip: its stages left to right as they process the voice (low cut, de-esser,
/// compressor, EQ, output), each with its knob and what it's doing.
struct VocalStripView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 860 × 360.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        HStack(alignment: .top, spacing: 10) {
          stage("Low Cut") {
            HintKnob(parameter: parameters["lowCut"], name: "Frequency",
              help: "Cuts rumble, handling noise and pops below this.", hint: $hint, tint: blue)
          }
          arrow
          stage("De-Ess") {
            HintKnob(parameter: parameters["deEss"], name: "Amount", help: "Softens harsh \u{201C}ss\u{201D} and \u{201C}t\u{201D} sounds.", hint: $hint)
            amount(meters?.value(.firstPad) ?? 0)
          }
          arrow
          stage("Compress") {
            HintKnob(parameter: parameters["compress"], name: "Amount",
              help: "Evens out the level so quiet words are heard and loud ones don't jump out.", hint: $hint)
            amount(meters?.reduction ?? 0)
          }
          arrow
          stage("EQ") {
            HStack(spacing: 0) {
              HintKnob(parameter: parameters["body"], name: "Body", help: "Warmth and weight, around 220 Hz.", hint: $hint, tint: green, diameter: 40)
              HintKnob(parameter: parameters["presence"], name: "Presence",
                help: "Clarity and forwardness, around 4.5 kHz.", hint: $hint, tint: green, diameter: 40)
              HintKnob(parameter: parameters["air"], name: "Air", help: "Breathiness and sparkle, above 12 kHz.", hint: $hint, tint: green, diameter: 40)
            }
          }
          .frame(width: 230)
          arrow
          stage("Output") {
            HStack(spacing: 8) {
              HintKnob(parameter: parameters["output"], name: "Level", help: "The level out.", hint: $hint, tint: green, diameter: 40)
              InOutMeters(meters: meters).frame(height: 120)
            }
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private var arrow: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(EffectStyle.label.opacity(0.6))
      .frame(height: 200)
  }

  private func stage(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(spacing: 10) {
      Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(orange)
      content()
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 6).fill(EffectStyle.panel))
  }

  /// How much a stage is turning the voice down right now.
  private func amount(_ reduction: Float) -> some View {
    VStack(spacing: 3) {
      GeometryReader { geometry in
        let fraction = CGFloat(min(1, max(0, -reduction / 18)))
        ZStack(alignment: .trailing) {
          RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.55))
          RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.98, green: 0.4, blue: 0.25)).frame(width: geometry.size.width * fraction)
        }
      }
      .frame(height: 8)
      Text(String(format: "%.1f dB", min(0, reduction))).font(.system(size: 9).monospacedDigit()).foregroundStyle(EffectStyle.label)
    }
    .accessibilityElement(children: .combine)
  }
}
