//
//  SamplerView.swift
//  OngakuEffects
//

import AppKit
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

/// The Sampler's panel, laid out like Logic's Quick Sampler: the sample's waveform with its
/// markers and loop, how it plays, then pitch, filter and LFO, the envelopes, and a
/// keyboard (with the root note marked) to play it.
struct SamplerView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let tree: ObservableAUParameterGroup

  @State private var hint: String?
  @State private var octave = 3
  @State private var isTargeted = false

  static let accent = Color(red: 0.3, green: 0.85, blue: 0.78)

  private var display: SamplerDisplay { audioUnit.samplerDisplay }

  private func p(_ identifier: String) -> ObservableAUParameter? {
    tree.children[identifier] as? ObservableAUParameter
  }

  private func value(_ identifier: String) -> Double {
    Double(p(identifier)?.value ?? 0)
  }

  var body: some View {
    // Laid out for 1180 × 700.
    VStack(spacing: 10) {
      header.frame(height: 58)
      sample.frame(height: 200)
      HStack(alignment: .top, spacing: 10) {
        pitch.frame(width: 300)
        filter.frame(width: 452)
        lfo.frame(width: 368)
      }
      .frame(height: 150)
      HStack(alignment: .top, spacing: 10) {
        envelope(title: "Filter Envelope", prefix: "filter", accent: Synth.filter, extra: nil)
          .frame(width: 540)
        envelope(title: "Amp Envelope", prefix: "amp", accent: Synth.envelope, extra: "velocity")
          .frame(width: 590)
      }
      .frame(height: 130)
      hintLine.frame(height: 18)
      keyboardRow.frame(height: 62)
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
        Text("SAMPLER")
          .font(.system(size: 18, weight: .heavy))
          .tracking(3)
          .foregroundStyle(Synth.value)
        Text("ONGAKU")
          .font(.system(size: 8, weight: .bold))
          .tracking(4)
          .foregroundStyle(Self.accent)
      }
      Spacer()
      loadButton
      Spacer()
      HStack(spacing: 14) {
        if let voices = p("voices") {
          VStack(spacing: 3) {
            Text("VOICES").font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Synth.label)
            SynthButtons(parameter: voices, options: [("Poly: play chords", .text("POLY")), ("Mono: one note at a time", .text("MONO"))],
              accent: Self.accent, buttonWidth: 38)
          }
          .help("Poly plays chords. Mono plays one note at a time and glides between notes played legato.")
          .onHover { hover($0, "Poly plays chords. Mono plays one note at a time and glides between notes played legato.") }
        }
        knob("glide", "Glide", "How long notes take to slide into each other.", Self.accent, size: 30)
        knob("bendRange", "Bend", "How far the pitch bend wheel bends, in semitones.", Self.accent, size: 30)
        knob("gain", "Volume", "The sampler's overall volume.", Self.accent, size: 30)
      }
    }
  }

  private var loadButton: some View {
    Button {
      chooseFile()
    } label: {
      Label("Load Sample…", systemImage: "waveform.badge.plus")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Synth.value)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Self.accent.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Self.accent.opacity(0.6), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help("Choose an audio file to play, or drag one onto the waveform.")
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.message = "Choose a sound for the Sampler to play."
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { load(url) }
    }
  }

  private func load(_ url: URL) {
    audioUnit.loadSample(from: url)
  }

  // MARK: - Sample

  private var sampleTitle: String {
    guard let name = display.name else { return "Sample" }
    let channels = display.channelCount > 1 ? "Stereo" : "Mono"
    return "Sample · \(name) · \(String(format: "%.2f", display.duration)) s · \(channels)"
  }

  private var sample: some View {
    SynthSection(title: sampleTitle, accent: Self.accent) {
      HStack(alignment: .top, spacing: 12) {
        waveform
        VStack(alignment: .leading, spacing: 8) {
          labelled("Mode", buttons("playMode", width: 56, [
            ("Classic: plays while the key is held", .text("CLASSIC")), ("One Shot: plays to the end, whatever the key does", .text("1 SHOT")),
          ], help: "Classic plays while you hold the key, and can loop. One Shot plays the whole sample from one tap, for drums and hits."))
          HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
              labelled("Loop", buttons("loop", width: 38, [
                ("Off", .text("OFF")), ("Forward: from the loop's end back to its start", .text("FWD")),
                ("Alternate: back and forth", .text("ALT")),
              ], help: "Loops the part between the loop markers while the key is held, so short sounds can sustain."))
              labelled("Direction", buttons("reverse", width: 38, [("Forward", .text("FWD")), ("Reverse: plays the sample backwards", .text("REV"))],
                help: "Plays the sample forwards or backwards."))
            }
            knob("crossfade", "X-Fade", "Blends the loop's end into its start so the jump is smooth.", Self.accent, size: 32)
          }
        }
        .frame(width: 196, alignment: .leading)
      }
    }
  }

  private func labelled(_ title: String, _ content: some View) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Synth.label)
      content
    }
  }

  @ViewBuilder
  private var waveform: some View {
    if let start = p("start"), let end = p("end"), let loopStart = p("loopStart"), let loopEnd = p("loopEnd") {
      SampleWaveform(
        audioUnit: audioUnit, overview: display.overview, start: start, end: end, loopStart: loopStart, loopEnd: loopEnd,
        isLooping: value("loop") >= 0.5 && value("playMode") < 0.5, accent: Self.accent, isTargeted: isTargeted,
        error: display.error, load: chooseFile)
        // What was left out of a long or many-channel file: it still loads, cut to fit.
        .overlay(alignment: .bottom) {
          if let notice = display.notice, !display.overview.isEmpty {
            Text(notice)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
              .padding(.bottom, 6)
              .allowsHitTesting(false)
          }
        }
        .dropDestination(for: URL.self) { urls, _ in
          guard let url = urls.first else { return false }
          load(url)
          return true
        } isTargeted: { isTargeted = $0 }
        .onHover { hover($0, "Drag the markers: S and E set where the sample starts and ends; the loop markers set what repeats while a key is held.") }
    }
  }

  // MARK: - Pitch, filter and LFO

  private var pitch: some View {
    SynthSection(title: "Pitch", accent: Synth.oscillator) {
      HStack(alignment: .top, spacing: 2) {
        knob("root", "Root Note", "The key that plays the sample at its own pitch (found for you when it has a clear pitch).", Synth.oscillator, size: 44)
        knob("transpose", "Transpose", "Shifts the whole sample up or down in semitones.", Synth.oscillator, size: 34)
        knob("tune", "Fine", "Tunes the sample in cents.", Synth.oscillator, size: 34)
        labelled("Follow Keys", buttons("followKeys", width: 42, [
          ("Fixed: every key plays the sample at its own pitch", .text("FIXED")), ("Keys: the pitch follows the keyboard", .text("KEYS")),
        ], help: "Whether the pitch follows the keys. Fixed is for drums and sound effects."))
      }
    }
  }

  private var filter: some View {
    SynthSection(title: "Filter · 24 dB Low-Pass", accent: Synth.filter) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 6) {
          buttons("filterOn", width: 34, [("Off", .text("OFF")), ("On", .text("ON"))], help: "Turns the filter on, to darken or shape the sample.")
          FilterScope(cutoff: value("cutoff"), resonance: value("resonance") / 100)
            .opacity(value("filterOn") >= 0.5 ? 1 : 0.35)
            .frame(width: 150, height: 70)
        }
        HStack(alignment: .top, spacing: 0) {
          knob("cutoff", "Cutoff", "The filter's brightness: turn it down for a darker, warmer sound.", Synth.filter, size: 44)
          knob("resonance", "Resonance", "Boosts the sound at the cutoff, for a sharper tone.", Synth.filter, size: 36)
          knob("filterEnv", "Env Amount", "How much the filter envelope opens the filter on each note.", Synth.filter, size: 36)
          knob("keyTrack", "Key Track", "Opens the filter more for higher notes.", Synth.filter, size: 36)
        }
      }
    }
  }

  private var lfo: some View {
    SynthSection(title: "LFO", accent: Synth.lfo) {
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: 6) {
          LFOScope(rate: value("lfoRate"), wave: Int(value("lfoWave")))
            .frame(width: 96, height: 60)
          buttons("lfoWave", [("Triangle: a smooth wobble", .triangle), ("Square: jumps between two values", .square),
                              ("Random: a new value each cycle", .random)], help: "The LFO's shape.")
        }
        HStack(alignment: .top, spacing: 0) {
          knob("lfoRate", "Rate", "How fast the LFO wobbles.", Synth.lfo, size: 32)
          knob("lfoPitch", "Vibrato", "How much the LFO wobbles the pitch. The mod wheel adds more.", Synth.lfo, size: 32)
          knob("lfoFilter", "Wah", "How much the LFO moves the filter cutoff.", Synth.lfo, size: 32)
          knob("lfoAmp", "Tremolo", "How much the LFO wobbles the volume.", Synth.lfo, size: 32)
        }
      }
    }
  }

  // MARK: - Envelopes

  private func envelope(title: String, prefix: String, accent: Color, extra: String?) -> some View {
    let isFilter = prefix == "filter"
    return SynthSection(title: title, accent: accent) {
      HStack(alignment: .top, spacing: 8) {
        EnvelopeScope(
          attack: value("\(prefix)Attack"), decay: value("\(prefix)Decay"), sustain: value("\(prefix)Sustain") / 100,
          release: value("\(prefix)Release"), color: accent)
          .frame(width: 150, height: 86)
        HStack(alignment: .top, spacing: 0) {
          knob("\(prefix)Attack", "Attack", isFilter ? "How long the filter takes to open when a note starts." : "How long a note takes to fade in.", accent, size: 36)
          knob("\(prefix)Decay", "Decay", "How long it then takes to fall to the sustain level.", accent, size: 36)
          knob("\(prefix)Sustain", "Sustain", isFilter ? "How open the filter stays while a key is held." : "How loud a note stays while the key is held.", accent, size: 36)
          knob("\(prefix)Release", "Release", isFilter ? "How long the filter takes to close after the key is let go." : "How long a note rings on after the key is let go.", accent, size: 36)
          if let extra {
            knob(extra, "Velocity", "How much playing harder makes notes louder.", accent, size: 36)
          }
        }
      }
    }
  }

  // MARK: - Hint and keyboard

  private var hintLine: some View {
    HStack(spacing: 6) {
      Image(systemName: hint == nil ? "lightbulb" : "info.circle").foregroundStyle(Self.accent)
      Text(hint ?? display.error ?? (display.name == nil
        ? "Drag an audio file onto the waveform, or click Load Sample…, then play it from the keys. The sample is saved with the song."
        : "Play from the keys: the dot marks the root note, where the sample plays at its own pitch. Double-click or Option-click a knob to reset it."))
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
          Button { octave = max(0, octave - 1) } label: { Image(systemName: "minus") }
          Text("C\(octave - 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Synth.value).frame(width: 26)
          Button { octave = min(6, octave + 1) } label: { Image(systemName: "plus") }
        }
        .controlSize(.small)
      }
      .frame(width: 92)
      PlayableKeyboard(lowestNote: (octave + 1) * 12, octaves: 4, accent: Self.accent, markedNote: Int(value("root").rounded())) {
        note, isDown in
        audioUnit.playNote(note, velocity: isDown ? 100 : 0)
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
    _ identifier: String, width: CGFloat = 28, _ options: [(name: String, glyph: WaveGlyph.Kind)], help: String
  ) -> some View {
    if let parameter = p(identifier) {
      SynthButtons(parameter: parameter, options: options, accent: Self.accent, buttonWidth: width)
        .help(help)
        .onHover { hover($0, help) }
    }
  }
}

/// The sample's waveform, with draggable start and end markers (S, E), the loop between
/// its markers, and a playhead for each sounding note.
private struct SampleWaveform: View {
  let audioUnit: OngakuEffectsAudioUnit
  let overview: [Float]
  let start: ObservableAUParameter
  let end: ObservableAUParameter
  let loopStart: ObservableAUParameter
  let loopEnd: ObservableAUParameter
  let isLooping: Bool
  let accent: Color
  let isTargeted: Bool
  let error: String?
  let load: () -> Void

  var body: some View {
    SynthScreen {
      GeometryReader { proxy in
        let size = proxy.size
        ZStack(alignment: .topLeading) {
          if overview.isEmpty {
            empty
          } else {
            picture(size: size)
            playheads(size: size)
            marker(start, label: "S", at: .top, flagSide: 1, color: accent, size: size)
            marker(end, label: "E", at: .top, flagSide: -1, color: accent, size: size)
            if isLooping {
              marker(loopStart, label: "▸", at: .bottom, flagSide: 1, color: Synth.lfo, size: size)
              marker(loopEnd, label: "◂", at: .bottom, flagSide: -1, color: Synth.lfo, size: size)
            }
          }
        }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent, lineWidth: isTargeted ? 2 : 0))
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "waveform.badge.plus").font(.system(size: 28)).foregroundStyle(accent)
      Text("Drag an audio file here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Synth.value)
      Button("Load Sample…", action: load).controlSize(.small)
      if let error {
        Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Synth.label.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        .padding(10))
  }

  private func x(_ parameter: ObservableAUParameter, _ size: CGSize) -> CGFloat {
    CGFloat(parameter.value / 100) * size.width
  }

  private func picture(size: CGSize) -> some View {
    let (overview, accent, isLooping) = (overview, accent, isLooping)
    let startX = x(start, size), endX = x(end, size)
    let loopFrom = x(loopStart, size), loopTo = x(loopEnd, size)
    return Canvas { context, size in
      let middle = size.height / 2
      let barWidth = size.width / CGFloat(overview.count)
      var wave = Path()
      for (index, peak) in overview.enumerated() {
        let height = max(0.5, CGFloat(peak) * (size.height / 2 - 6))
        wave.addRect(CGRect(x: CGFloat(index) * barWidth, y: middle - height, width: max(1, barWidth * 0.8), height: height * 2))
      }
      context.fill(wave, with: .color(accent.opacity(0.85)))
      // What isn't played is shaded.
      context.fill(Path(CGRect(x: 0, y: 0, width: min(startX, endX), height: size.height)), with: .color(.black.opacity(0.6)))
      context.fill(Path(CGRect(x: max(startX, endX), y: 0, width: size.width - max(startX, endX), height: size.height)),
        with: .color(.black.opacity(0.6)))
      if isLooping {
        let loop = CGRect(x: min(loopFrom, loopTo), y: 0, width: abs(loopTo - loopFrom), height: size.height)
        context.fill(Path(loop), with: .color(Synth.lfo.opacity(0.14)))
        context.fill(Path(CGRect(x: loop.minX, y: size.height - 4, width: loop.width, height: 4)), with: .color(Synth.lfo.opacity(0.8)))
      }
    }
  }

  /// A line for each sounding note, where it's playing.
  private func playheads(size: CGSize) -> some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
      let positions = (0..<(Int(OngakuMeter.count.rawValue) - Int(OngakuMeter.firstPlayhead.rawValue))).compactMap { index -> Float? in
        let meter = OngakuMeter(rawValue: OngakuMeter.firstPlayhead.rawValue + Int32(index)) ?? .firstPlayhead
        let position = OngakuMeterValue(audioUnit.meters, meter)
        return position >= 0 ? position : nil
      }
      Canvas { context, size in
        for position in positions {
          let x = CGFloat(position) * size.width
          context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white.opacity(0.85)))
        }
      }
    }
    .allowsHitTesting(false)
  }

  /// `flagSide` puts the flag to the right (1) or left (−1) of the line, inside the
  /// played part, so the flags at the sample's ends aren't cut off.
  private func marker(
    _ parameter: ObservableAUParameter, label: String, at edge: VerticalEdge, flagSide: CGFloat, color: Color, size: CGSize
  ) -> some View {
    MarkerHandle(parameter: parameter, label: label, edge: edge, flagSide: flagSide, color: color, width: size.width, height: size.height)
      .position(x: x(parameter, size), y: size.height / 2)
  }
}

/// A marker's line and its flag, which drags it along the sample.
private struct MarkerHandle: View {
  let parameter: ObservableAUParameter
  let label: String
  let edge: VerticalEdge
  let flagSide: CGFloat
  let color: Color
  let width: CGFloat
  let height: CGFloat

  @State private var dragStart: AUValue?

  var body: some View {
    ZStack(alignment: edge == .top ? .top : .bottom) {
      Rectangle().fill(color).frame(width: 1.5, height: height)
      Text(label)
        .font(.system(size: 9, weight: .heavy))
        .foregroundStyle(.black)
        .frame(width: 16, height: 14)
        .background(RoundedRectangle(cornerRadius: 3).fill(color))
        .offset(x: flagSide * 8)
    }
    .frame(width: 32, height: height)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { drag in
          if dragStart == nil {
            dragStart = parameter.value
            parameter.onEditingChanged(true)
          }
          let moved = AUValue(drag.translation.width / max(1, width) * 100)
          parameter.value = parameter.clamp((dragStart ?? parameter.value) + moved)
        }
        .onEnded { _ in
          dragStart = nil
          parameter.onEditingChanged(false)
        })
    .onHover { inside in
      if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
    .accessibilityElement()
    .accessibilityLabel(parameter.displayName)
    .accessibilityValue(parameter.text)
  }
}
