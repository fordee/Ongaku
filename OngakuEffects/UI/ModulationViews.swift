//
//  ModulationViews.swift
//  OngakuEffects
//

import SwiftUI

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)
private let purple = Color(red: 0.68, green: 0.45, blue: 0.98)

/// The Chorus, Flanger, Phaser and Tremolo: their wave turning (with a dot where it is now,
/// and what it sweeps), and their controls.
struct ModulationView: View {
  let effect: OngakuEffect
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
            WavePicture(
              shape: effect == .tremolo ? Int(parameters.value("shape").rounded()) : 0,
              phase: Double(meters?.value(.LFO) ?? 0),
              stereoOffset: stereoOffset, caption: caption, tint: tint)
            if effect == .tremolo {
              HStack(spacing: 6) {
                LevelBar(title: "L", level: Double(meters?.value(.tremoloLeft) ?? 1))
                LevelBar(title: "R", level: Double(meters?.value(.tremoloRight) ?? 1))
              }
            }
            InOutMeters(meters: meters)
          }
          .frame(height: 150)
          controls
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private var tint: Color {
    switch effect {
    case .chorus: blue
    case .flanger: purple
    case .phaser: green
    default: orange
    }
  }

  /// How far the right side's wave is from the left's (of a cycle), for the second dot.
  private var stereoOffset: Double {
    switch effect {
    case .chorus: Double(parameters.value("width")) / 100 * 0.25
    case .flanger, .phaser: Double(parameters.value("width")) / 100 * 0.5
    case .tremolo: Double(parameters.value("stereo")) / 360
    default: 0
    }
  }

  /// What the wave sweeps, in its own units.
  private var caption: String {
    switch effect {
    case .chorus:
      let delay = parameters.value("delay"), sweep = min(4, delay * 0.8) * parameters.value("depth") / 100
      return String(format: "Delay %.1f–%.1f ms", delay - sweep, delay + sweep)
    case .flanger:
      let delay = parameters.value("delay"), swing = min(delay * 4, 8) * parameters.value("depth") / 100
      return String(format: "Delay %.1f–%.1f ms", delay, delay + swing)
    case .phaser:
      let center = parameters.value("center"), octaves = 2 * parameters.value("depth") / 100
      return "\(Self.hertz(center / pow(2, octaves))) – \(Self.hertz(center * pow(2, octaves)))"
    default:
      return parameters.value("sync") >= 0.5
        ? "One cycle every \(DelayParameters.notes[min(10, max(0, Int(parameters.value("note").rounded())))])"
        : String(format: "%.1f cycles a second", parameters.value("rate"))
    }
  }

  private static func hertz(_ value: Float) -> String {
    value >= 1_000 ? String(format: "%.1f kHz", value / 1_000) : String(format: "%.0f Hz", value)
  }

  @ViewBuilder private var controls: some View {
    HStack(spacing: 0) {
      switch effect {
      case .chorus:
        HintKnob(parameter: parameters["rate"], name: "Rate", help: "How fast the copies' pitch wavers.", hint: $hint)
        HintKnob(parameter: parameters["depth"], name: "Depth", help: "How far it wavers: a little thickens, a lot sounds seasick.", hint: $hint)
        HintKnob(parameter: parameters["delay"], name: "Delay", help: "How far behind the copies are. Longer sounds more like separate players.", hint: $hint, tint: purple)
        HintKnob(parameter: parameters["width"], name: "Width", help: "How differently the left and right sides waver, for a wider sound.", hint: $hint, tint: blue)
        HintKnob(parameter: parameters["mix"], name: "Mix", help: "How much chorus against the original. 100 % is vibrato.", hint: $hint, tint: green)
      case .flanger:
        HintKnob(parameter: parameters["rate"], name: "Rate", help: "How fast the whoosh sweeps up and down.", hint: $hint)
        HintKnob(parameter: parameters["depth"], name: "Depth", help: "How far it sweeps.", hint: $hint)
        HintKnob(parameter: parameters["delay"], name: "Delay", help: "Where the sweep starts: shorter is higher and more metallic.", hint: $hint, tint: purple)
        HintKnob(parameter: parameters["feedback"], name: "Feedback", help: "How much rings: higher is more resonant; below zero sounds hollow.", hint: $hint, tint: purple)
        HintKnob(parameter: parameters["width"], name: "Width", help: "How far apart the left and right sweeps are.", hint: $hint, tint: blue)
        HintKnob(parameter: parameters["mix"], name: "Mix", help: "How much of the flanged sound. Full mix gives the deepest notches.", hint: $hint, tint: green)
      case .phaser:
        HintKnob(parameter: parameters["rate"], name: "Rate", help: "How fast the notches sweep.", hint: $hint)
        HintKnob(parameter: parameters["depth"], name: "Depth", help: "How far either side of the centre they sweep (up to two octaves).", hint: $hint)
        HintKnob(parameter: parameters["center"], name: "Centre", help: "The middle of the sweep.", hint: $hint, tint: purple)
        HintKnob(parameter: parameters["feedback"], name: "Feedback", help: "How sharp and resonant the notches are.", hint: $hint, tint: purple)
        HintKnob(parameter: parameters["width"], name: "Width", help: "How far apart the left and right sweeps are.", hint: $hint, tint: blue)
        HintKnob(parameter: parameters["mix"], name: "Mix", help: "How much of the phased sound. Full mix gives the deepest notches.", hint: $hint, tint: green)
        VStack(spacing: 6) {
          Text("Stages").font(.system(size: 10, weight: .semibold)).foregroundStyle(EffectStyle.label)
          ParameterPicker(parameter: parameters["stages"], options: ModulationParameters.stages,
            help: "How many filters: more stages, more notches and a stronger effect.", hint: $hint)
        }
      default:
        VStack(spacing: 8) {
          ParameterToggle(parameter: parameters["sync"], title: "Sync to Tempo",
            help: "On, the rate is a note value at the song's tempo; off, it's in hertz.", hint: $hint)
          ParameterPicker(parameter: parameters["shape"], options: ModulationParameters.shapes,
            help: "Sine is smooth, triangle steady, square chops the sound on and off.", hint: $hint)
        }
        if parameters.value("sync") >= 0.5 {
          HintKnob(parameter: parameters["note"], name: "Note", help: "How long one cycle lasts, in notes at the song's tempo.", hint: $hint)
        } else {
          HintKnob(parameter: parameters["rate"], name: "Rate", help: "How many times a second the level rises and falls.", hint: $hint)
        }
        HintKnob(parameter: parameters["depth"], name: "Depth", help: "How far the level falls: 100 % goes all the way to silence.", hint: $hint)
        HintKnob(parameter: parameters["stereo"], name: "Stereo", help: "How far apart the left and right waves are. At 180° the sound pans side to side.", hint: $hint, tint: blue)
      }
    }
  }
}

/// One cycle of the wave, with a dot for each side where it is now.
private struct WavePicture: View {
  let shape: Int
  let phase: Double
  let stereoOffset: Double
  let caption: String
  let tint: Color

  var body: some View {
    let (shape, phase, stereoOffset, caption, tint) = (shape, phase, stereoOffset, caption, tint)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      let inset: CGFloat = 14
      func value(_ phase: Double) -> Double {
        let wrapped = phase - floor(phase)
        return switch shape {
        case 1: wrapped < 0.5 ? wrapped * 2 : 2 - wrapped * 2
        case 2: wrapped < 0.5 ? 1 : 0
        default: 0.5 + 0.5 * cos(2 * .pi * wrapped)
        }
      }
      func point(_ phase: Double) -> CGPoint {
        CGPoint(x: inset + CGFloat(phase) * (size.width - inset * 2),
          y: size.height - 22 - CGFloat(value(phase)) * (size.height - 44))
      }
      context.stroke(Path { $0.move(to: CGPoint(x: inset, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width - inset, y: size.height / 2)) },
        with: .color(EffectStyle.grid))
      var wave = Path()
      for step in 0...200 {
        let p = point(Double(step) / 200)
        if step == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
      }
      context.stroke(wave, with: .color(tint.opacity(0.85)), lineWidth: 2)
      // Left, then right (if it's elsewhere).
      for (offset, label) in [(0.0, "L"), (stereoOffset, "R")] where label == "L" || stereoOffset > 0.001 {
        let at = phase + offset
        let dot = point(at - floor(at))
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)), with: .color(.white))
        context.draw(Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.black), at: dot)
      }
      context.draw(Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: size.width / 2, y: size.height - 9))
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Modulation wave")
    .accessibilityValue(caption)
  }
}

/// A side's level through the Tremolo, from silent to full.
private struct LevelBar: View {
  let title: String
  let level: Double

  var body: some View {
    VStack(spacing: 4) {
      GeometryReader { geometry in
        ZStack(alignment: .bottom) {
          RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.55))
          RoundedRectangle(cornerRadius: 3).fill(orange)
            .frame(height: geometry.size.height * CGFloat(min(max(level, 0), 1)))
        }
      }
      .frame(width: 14)
      Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(EffectStyle.label)
    }
    .accessibilityElement()
    .accessibilityLabel("\(title) level")
    .accessibilityValue("\(Int(level * 100)) percent")
  }
}

#Preview("Chorus") {
  PluginPreview(effect: .chorus) { audioUnit in
    audioUnit.meters[Int(OngakuMeter.LFO.rawValue)] = 0.3
  }
}

#Preview("Phaser") {
  PluginPreview(effect: .phaser, values: [.phsStages: 3])
}

#Preview("Tremolo, auto-pan") {
  PluginPreview(effect: .tremolo, values: [.trmDepth: 100, .trmStereo: 180]) { audioUnit in
    audioUnit.meters[Int(OngakuMeter.LFO.rawValue)] = 0.2
    audioUnit.meters[Int(OngakuMeter.tremoloLeft.rawValue)] = 0.9
    audioUnit.meters[Int(OngakuMeter.tremoloRight.rawValue)] = 0.1
  }
}
