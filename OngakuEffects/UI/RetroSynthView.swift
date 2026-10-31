//
//  RetroSynthView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Retro Synth's front panel, laid out like Logic's synths: the global settings on top
/// (patches are the header's presets); the oscillators, unison and filter; then the envelopes and LFO; and a
/// keyboard to play it.
struct RetroSynthView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let tree: ObservableAUParameterGroup

  @State private var hint: String?
  @State private var octave = 3

  private func p(_ identifier: String) -> ObservableAUParameter? {
    tree.children[identifier] as? ObservableAUParameter
  }

  private func value(_ identifier: String) -> Double {
    Double(p(identifier)?.value ?? 0)
  }

  var body: some View {
    // Laid out for 1180 × 610.
    VStack(spacing: 10) {
      header
        .frame(height: 40)
      HStack(alignment: .top, spacing: 10) {
        oscillators.frame(width: 572)
        unison.frame(width: 168)
        filter.frame(width: 360)
      }
      .frame(height: 236)
      HStack(alignment: .top, spacing: 10) {
        envelope(title: "Filter Envelope", prefix: "filter", accent: Synth.filter, extra: nil)
          .frame(width: 330)
        envelope(title: "Amp Envelope", prefix: "amp", accent: Synth.envelope, extra: "velocity")
          .frame(width: 394)
        lfo.frame(width: 376)
      }
      .frame(height: 170)
      hintLine
        .frame(height: 18)
      keyboardRow
        .frame(height: 62)
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
        Text("RETRO SYNTH")
          .font(.system(size: 18, weight: .heavy))
          .tracking(3)
          .foregroundStyle(Synth.value)
        Text("ONGAKU")
          .font(.system(size: 8, weight: .bold))
          .tracking(4)
          .foregroundStyle(Synth.oscillator)
      }
      Spacer()
      HStack(spacing: 14) {
        if let mode = p("mode") {
          VStack(spacing: 3) {
            Text("VOICES").font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Synth.label)
            SynthButtons(parameter: mode, options: [("Poly: play chords", .text("POLY")), ("Mono: one note at a time", .text("MONO"))],
              accent: Synth.oscillator)
          }
          .help("Poly plays chords. Mono plays one note at a time and glides between notes played legato.")
          .onHover { hover($0, "Poly plays chords. Mono plays one note at a time and glides between notes played legato.") }
        }
        knob("glide", "Glide", "How long notes take to slide into each other.", Synth.oscillator, size: 30)
        knob("bendRange", "Bend", "How far the pitch bend wheel bends, in semitones.", Synth.oscillator, size: 30)
        knob("gain", "Volume", "The synth's overall volume.", Synth.oscillator, size: 30)
      }
    }
  }

  // MARK: - Helpers

  private func hover(_ isHovering: Bool, _ help: String) {
    hint = isHovering ? help : (hint == help ? nil : hint)
  }

  @ViewBuilder
  private func knob(_ identifier: String, _ label: String, _ help: String, _ accent: Color, size: CGFloat = 40) -> some View {
    if let parameter = p(identifier) {
      SynthKnob(parameter: parameter, label: label, accent: accent, size: size)
      .help(help)
      .onHover { hover($0, help) }
    }
  }

  @ViewBuilder
  private func buttons(
    _ identifier: String, _ options: [(name: String, glyph: WaveGlyph.Kind)], _ accent: Color, help: String
  ) -> some View {
    if let parameter = p(identifier) {
      SynthButtons(parameter: parameter, options: options, accent: accent)
        .help(help)
        .onHover { hover($0, help) }
    }
  }

  private let waves: [(name: String, glyph: WaveGlyph.Kind)] = [
    ("Saw: bright and buzzy", .saw), ("Pulse: hollow and reedy", .pulse), ("Triangle: soft and round", .triangle),
    ("Sine: pure", .sine),
  ]

  // MARK: - Oscillators

  private var oscillators: some View {
    SynthSection(title: "Oscillators", accent: Synth.oscillator) {
      HStack(alignment: .top, spacing: 12) {
        // Oscillator 1.
        VStack(alignment: .leading, spacing: 8) {
          caption("Osc 1")
          buttons("osc1Wave", waves, Synth.oscillator, help: "Oscillator 1's wave: where the sound starts.")
          HStack(spacing: 2) {
            knob("pulseWidth", "Shape", "Oscillator 1's shape: the pulse's width, or how far a saw, triangle or sine skews.", Synth.oscillator)
            knob("fm", "FM", "Oscillator 2 bends oscillator 1's wave: from warm to bell-like and metallic.", Synth.oscillator)
          }
        }
        // The two waves, and how they're mixed.
        VStack(spacing: 6) {
          OscillatorScope(
            wave1: Int(value("osc1Wave")), shape1: value("pulseWidth") / 100,
            wave2: Int(value("osc2Wave")), shape2: value("osc2Shape") / 100,
            ratio: pow(2, (value("osc2Semitones") + value("osc2Detune") / 100) / 12), mode: Int(value("osc2Mode")),
            mix: value("oscMix") / 100, cutoff: value("cutoff"), resonance: value("resonance") / 100)
            .frame(height: 74)
          HStack(spacing: 2) {
            knob("oscMix", "Osc 1 ◂ ▸ Osc 2", "Blends the two oscillators: left is all Osc 1, right is all Osc 2.", Synth.oscillator, size: 44)
            knob("sub", "Sub", "A square wave an octave below oscillator 1, for weight in basses.", Synth.oscillator)
            knob("noise", "Noise", "Adds noise: breath for pads, a chiff for plucks.", Synth.oscillator)
          }
        }
        .frame(width: 206)
        // Oscillator 2.
        VStack(alignment: .leading, spacing: 8) {
          caption("Osc 2")
          buttons("osc2Wave", waves, Synth.oscillator, help: "Oscillator 2's wave. Two oscillators together sound richer.")
          buttons("osc2Mode", [
            ("Normal: oscillator 2 plays on its own", .text("NORM")),
            ("Sync: oscillator 2 restarts with oscillator 1; turn its Pitch for a tearing lead", .text("SYNC")),
            ("Ring: oscillator 2 multiplied by oscillator 1, for metallic, bell-like tones", .text("RING")),
          ], Synth.oscillator, help: "How oscillator 2 plays with oscillator 1.")
          HStack(spacing: 2) {
            knob("osc2Shape", "Shape", "Oscillator 2's shape.", Synth.oscillator, size: 34)
            knob("osc2Semitones", "Pitch", "Tunes oscillator 2 in semitones: +12 is an octave, +7 a fifth. In Sync, sweep this.", Synth.oscillator, size: 34)
            knob("osc2Detune", "Fine", "Tunes oscillator 2 slightly, for a thick, chorused sound.", Synth.oscillator, size: 34)
          }
        }
      }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 9, weight: .bold))
      .tracking(1)
      .foregroundStyle(Synth.value)
  }

  // MARK: - Unison

  private var unison: some View {
    SynthSection(title: "Unison", accent: Synth.unison) {
      VStack(spacing: 8) {
        UnisonPicture(voices: Int(value("unison")), detune: value("unisonDetune") / 100, spread: value("unisonSpread") / 100)
          .frame(height: 50)
        knob("unison", "Voices", "How many copies of each note play at once: more is thicker and wider.", Synth.unison, size: 40)
        HStack(spacing: 2) {
          knob("unisonDetune", "Detune", "How far apart the copies are tuned.", Synth.unison, size: 32)
          knob("unisonSpread", "Spread", "How widely the copies spread across the stereo field.", Synth.unison, size: 32)
        }
      }
      .frame(maxWidth: .infinity)
    }
  }

  // MARK: - Filter

  private var filter: some View {
    SynthSection(title: "Filter · 24 dB Low-Pass", accent: Synth.filter) {
      VStack(spacing: 8) {
        FilterScope(cutoff: value("cutoff"), resonance: value("resonance") / 100)
          .frame(height: 78)
        HStack(alignment: .top, spacing: 4) {
          knob("cutoff", "Cutoff", "The filter's brightness: turn it down for a darker, warmer sound.", Synth.filter, size: 54)
          knob("resonance", "Resonance", "Boosts the sound at the cutoff, for a sharper, squelchy, vocal tone.", Synth.filter, size: 54)
          knob("filterEnv", "Env Amount", "How much the filter envelope opens the filter on each note (below 0 closes it).", Synth.filter, size: 38)
          knob("keyTrack", "Key Track", "Opens the filter more for higher notes, so they stay as bright as low ones.", Synth.filter, size: 38)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: - Envelopes and LFO

  private func envelope(title: String, prefix: String, accent: Color, extra: String?) -> some View {
    let isFilter = prefix == "filter"
    return SynthSection(title: title, accent: accent) {
      HStack(alignment: .top, spacing: 8) {
        EnvelopeScope(
          attack: value("\(prefix)Attack"), decay: value("\(prefix)Decay"), sustain: value("\(prefix)Sustain") / 100,
          release: value("\(prefix)Release"), color: accent)
          .frame(width: 96, height: 112)
        HStack(alignment: .top, spacing: 0) {
          knob("\(prefix)Attack", "Attack", isFilter ? "How long the filter takes to open when a note starts." : "How long a note takes to fade in: short for plucks, long for pads.", accent, size: 34)
          knob("\(prefix)Decay", "Decay", "How long it then takes to fall to the sustain level.", accent, size: 34)
          knob("\(prefix)Sustain", "Sustain", isFilter ? "How open the filter stays while a key is held." : "How loud a note stays while the key is held.", accent, size: 34)
          knob("\(prefix)Release", "Release", isFilter ? "How long the filter takes to close after the key is let go." : "How long a note rings on after the key is let go.", accent, size: 34)
          if let extra {
            knob(extra, "Velocity", "How much playing harder makes notes louder.", accent, size: 34)
          }
        }
      }
    }
  }

  private var lfo: some View {
    SynthSection(title: "LFO", accent: Synth.lfo) {
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: 6) {
          LFOScope(rate: value("lfoRate"), wave: Int(value("lfoWave")))
            .frame(width: 100, height: 80)
          buttons("lfoWave", [("Triangle: a smooth wobble", .triangle), ("Square: jumps between two values", .square),
                              ("Random: a new value each cycle", .random)], Synth.lfo, help: "The LFO's shape.")
        }
        HStack(alignment: .top, spacing: 0) {
          knob("lfoRate", "Rate", "How fast the LFO wobbles.", Synth.lfo, size: 34)
          knob("lfoPitch", "Vibrato", "How much the LFO wobbles the pitch. The mod wheel adds more.", Synth.lfo, size: 34)
          knob("lfoFilter", "Wah", "How much the LFO moves the filter cutoff.", Synth.lfo, size: 34)
          knob("lfoPulse", "PWM", "How much the LFO moves both oscillators' shape: a lively, shimmering sound.", Synth.lfo, size: 34)
        }
      }
    }
  }

  // MARK: - Hint and keyboard

  private var hintLine: some View {
    HStack(spacing: 6) {
      Image(systemName: hint == nil ? "lightbulb" : "info.circle").foregroundStyle(Synth.oscillator)
      Text(hint ?? "Start from a patch (the presets above), then shape it: oscillators, filter, envelopes. Double-click or Option-click a knob to reset it.")
        .foregroundStyle(hint == nil ? Synth.label : Synth.value)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
    }
    .font(.system(size: 11))
  }

  private var keyboardRow: some View {
    HStack(spacing: 10) {
      VStack(spacing: 4) {
        Text("OCTAVE").font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Synth.label)
        HStack(spacing: 4) {
          Button { octave = max(1, octave - 1) } label: { Image(systemName: "minus") }
          Text("C\(octave - 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Synth.value).frame(width: 26)
          Button { octave = min(6, octave + 1) } label: { Image(systemName: "plus") }
        }
        .controlSize(.small)
      }
      .frame(width: 92)
      PlayableKeyboard(lowestNote: (octave + 1) * 12, octaves: 4) { note, isDown in
        audioUnit.playNote(note, velocity: isDown ? 100 : 0)
      }
    }
  }
}

// MARK: - Scopes

/// A wave with its shape applied, as the synth plays it: the pulse's width, or a skew.
private func shapedWave(_ wave: Int, _ phase: Double, _ shape: Double) -> Double {
  let shape = min(0.95, max(0.05, shape))
  if wave == 1 { return phase < shape ? 1 : -1 }
  let warped = phase < shape ? phase * 0.5 / shape : 0.5 + (phase - shape) * 0.5 / (1 - shape)
  switch wave {
  case 0: return 2 * warped - 1
  case 2: return 4 * abs(warped - 0.5) - 1
  default: return sin(2 * .pi * warped)
  }
}

/// The two oscillators' waves (faint), and (bright) what's heard: them mixed, synced or
/// ring-modulated, then through the filter, for a C2. A closed filter rounds a square
/// almost into a sine, which is why the waves can sound alike in dark patches.
private struct OscillatorScope: View {
  let wave1: Int, shape1: Double
  let wave2: Int, shape2: Double
  let ratio: Double, mode: Int, mix: Double
  let cutoff: Double, resonance: Double

  /// The C2 (MIDI 48) the picture is drawn for, and how many points it's sampled at.
  private static let pitch = 130.81
  private static let points = 240

  var body: some View {
    let (wave1, shape1, wave2, shape2, ratio, mode, mix) = (wave1, shape1, wave2, shape2, ratio, mode, mix)
    let heard = Self.filtered(
      (0..<Self.points).map { index in
        let t = Double(index) / Double(Self.points) * 2
        let phase1 = t - floor(t)
        let phase2 = mode == 1 ? (phase1 * ratio).truncatingRemainder(dividingBy: 1) : (t * ratio).truncatingRemainder(dividingBy: 1)
        let one = shapedWave(wave1, phase1, shape1), two = shapedWave(wave2, phase2, shape2)
        return one * (1 - mix) + (mode == 2 ? one * two : two) * mix
      },
      cutoff: cutoff, resonance: resonance)
    SynthScreen {
      Canvas { context, size in
        func trace(_ value: (Double) -> Double) -> Path {
          var path = Path()
          for step in 0...240 {
            let t = Double(step) / 240 * 2  // two cycles of oscillator 1
            let point = CGPoint(x: CGFloat(t / 2) * size.width, y: size.height / 2 - CGFloat(value(t)) * size.height * 0.36)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
          }
          return path
        }
        func two(_ t: Double) -> Double {
          // In Sync, oscillator 2 starts again with each cycle of oscillator 1.
          let phase = mode == 1 ? ((t - floor(t)) * ratio).truncatingRemainder(dividingBy: 1) : (t * ratio).truncatingRemainder(dividingBy: 1)
          return shapedWave(wave2, phase, shape2)
        }
        func one(_ t: Double) -> Double { shapedWave(wave1, t - floor(t), shape1) }
        context.stroke(trace(one), with: .color(Synth.oscillator.opacity(0.28)), lineWidth: 1)
        context.stroke(trace(two), with: .color(Synth.value.opacity(0.18)), lineWidth: 1)
        // What's heard, after the filter.
        var path = Path()
        for (index, value) in heard.enumerated() {
          let point = CGPoint(
            x: CGFloat(index) / CGFloat(heard.count - 1) * size.width, y: size.height / 2 - CGFloat(value) * size.height * 0.36)
          if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        glow(path, Synth.oscillator, in: context)
        context.draw(Text("HEARD, C2").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Synth.oscillator.opacity(0.8)),
          at: CGPoint(x: size.width - 6, y: 8), anchor: .trailing)
      }
    }
  }

  /// Two cycles of a wave at C2, put through the 24 dB ladder: each harmonic scaled and
  /// shifted by the filter's response at its frequency (a discrete Fourier transform there
  /// and back).
  private static func filtered(_ samples: [Double], cutoff: Double, resonance: Double) -> [Double] {
    let count = samples.count
    let k = resonance * 3.9
    var output = [Double](repeating: 0, count: count)
    // The window holds two cycles, so harmonic h of C2 is bin 2h.
    for bin in 1...(count / 2 - 1) {
      var re = 0.0, im = 0.0
      for (index, sample) in samples.enumerated() {
        let angle = -2 * .pi * Double(bin * index) / Double(count)
        re += sample * cos(angle)
        im += sample * sin(angle)
      }
      // The ladder's response 1 / ((1 + s)^4 + k), normalised to unity below the cutoff.
      let w = Double(bin) / 2 * pitch / cutoff
      var dRe = 1.0, dIm = 0.0
      for _ in 0..<4 { (dRe, dIm) = (dRe - dIm * w, dIm + dRe * w) }
      dRe += k
      let scale = (1 + k) / (dRe * dRe + dIm * dIm)
      let (hRe, hIm) = (dRe * scale, -dIm * scale)
      let (yRe, yIm) = (re * hRe - im * hIm, re * hIm + im * hRe)
      for index in 0..<count {
        let angle = 2 * .pi * Double(bin * index) / Double(count)
        output[index] += 2 * (yRe * cos(angle) - yIm * sin(angle)) / Double(count)
      }
    }
    return output
  }
}

/// The unison copies as bars across the stereo field, spaced by their detune.
private struct UnisonPicture: View {
  let voices: Int
  let detune: Double
  let spread: Double

  var body: some View {
    let (voices, detune, spread) = (max(1, voices), detune, spread)
    SynthScreen {
      Canvas { context, size in
        for k in 0..<voices {
          let position: Double = voices == 1 ? 0 : Double(k) / Double(voices - 1) * 2 - 1
          let half: CGFloat = size.width / 2
          let x: CGFloat = half + CGFloat(position * spread) * (half - 10)
          let level: Double = 0.45 + 0.4 * (1 - abs(position) * detune)
          let height: CGFloat = size.height * CGFloat(level)
          let bar = CGRect(x: x - 2, y: size.height - 6 - height, width: 4, height: height)
          context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(Synth.unison.opacity(0.85)))
        }
        for (text, x) in [("L", CGFloat(8)), ("R", size.width - 8)] {
          context.draw(Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(Synth.label), at: CGPoint(x: x, y: 8))
        }
      }
    }
  }
}

/// The filter's response: flat, a resonant bump at the cutoff, then falling away.
struct FilterScope: View {
  let cutoff: Double
  let resonance: Double

  var body: some View {
    let cutoff = self.cutoff, k = resonance * 3.9
    SynthScreen {
      Canvas { context, size in
        func y(_ decibels: Double) -> CGFloat { size.height * 0.32 - CGFloat(decibels / 48) * size.height * 0.68 }
        var path = Path()
        for step in 0...160 {
          let frequency = 20 * pow(1_000, Double(step) / 160)
          let w = frequency / cutoff
          var re = 1.0, im = 0.0
          for _ in 0..<4 { (re, im) = (re - im * w, im + re * w) }
          re += k
          let decibels = max(-60, -10 * log10(re * re + im * im) + 20 * log10(1 + k))
          let point = CGPoint(x: CGFloat(step) / 160 * size.width, y: min(size.height, y(decibels)))
          if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(Gradient(colors: [Synth.filter.opacity(0.3), Synth.filter.opacity(0.02)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        glow(path, Synth.filter, in: context)
      }
    }
  }
}

/// An envelope's shape: up over the attack, down to the sustain, held, then the release.
struct EnvelopeScope: View {
  let attack: Double, decay: Double, sustain: Double, release: Double
  let color: Color

  var body: some View {
    let a = sqrt(attack), d = sqrt(decay), r = sqrt(release), hold = 25.0
    let total = a + d + hold + r
    let (sustain, color) = (sustain, color)
    SynthScreen {
      Canvas { context, size in
        func x(_ value: Double) -> CGFloat { 6 + CGFloat(value / total) * (size.width - 12) }
        func y(_ level: Double) -> CGFloat { size.height - 8 - CGFloat(level) * (size.height - 20) }
        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(0)))
        path.addLine(to: CGPoint(x: x(a), y: y(1)))
        path.addQuadCurve(to: CGPoint(x: x(a + d), y: y(sustain)), control: CGPoint(x: x(a + d * 0.2), y: y(sustain)))
        path.addLine(to: CGPoint(x: x(a + d + hold), y: y(sustain)))
        path.addQuadCurve(to: CGPoint(x: x(total), y: y(0)), control: CGPoint(x: x(a + d + hold + r * 0.2), y: y(0)))
        var fill = path
        fill.addLine(to: CGPoint(x: x(0), y: y(0)))
        context.fill(fill, with: .color(color.opacity(0.12)))
        glow(path, color, in: context)
        for (label, position) in [("A", a / 2), ("D", a + d / 2), ("S", a + d + hold / 2), ("R", a + d + hold + r / 2)] {
          context.draw(Text(label).font(.system(size: 7.5, weight: .bold)).foregroundStyle(Synth.label),
            at: CGPoint(x: x(position), y: 8))
        }
      }
    }
  }
}

/// The LFO's wave, with a dot running along it at the LFO's rate.
struct LFOScope: View {
  let rate: Double
  let wave: Int

  var body: some View {
    let rate = self.rate, wave = self.wave
    SynthScreen {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let phase = (timeline.date.timeIntervalSinceReferenceDate * min(rate, 15)).truncatingRemainder(dividingBy: 1)
        Canvas { context, size in
          func value(_ t: Double) -> Double {
            switch wave {
            case 0: return 1 - 4 * abs(t - 0.5)
            case 1: return t < 0.5 ? 1 : -1
            default: return [0.4, -0.6, 0.8, -0.2, 0.1, -0.9][Int(t * 6) % 6]
            }
          }
          var path = Path()
          for step in 0...120 {
            let t = Double(step) / 120
            let point = CGPoint(x: CGFloat(t) * size.width, y: size.height / 2 - CGFloat(value(t)) * size.height * 0.36)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
          }
          glow(path, Synth.lfo, in: context)
          let dot = CGPoint(x: CGFloat(phase) * size.width, y: size.height / 2 - CGFloat(value(phase)) * size.height * 0.36)
          context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
      }
    }
  }
}
