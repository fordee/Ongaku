//
//  ReverbView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Reverb's parameters.
@MainActor
struct ReverbControls {
  let predelay, decay, size, diffusion, highCut, lowCut, modulation, width, mix: ObservableAUParameter

  init?(_ tree: ObservableAUParameterGroup) {
    func parameter(_ identifier: String) -> ObservableAUParameter? {
      tree.children[identifier] as? ObservableAUParameter
    }
    guard let predelay = parameter("predelay"), let decay = parameter("decay"), let size = parameter("size"),
      let diffusion = parameter("diffusion"), let highCut = parameter("highCut"), let lowCut = parameter("lowCut"),
      let modulation = parameter("modulation"), let width = parameter("width"), let mix = parameter("mix")
    else { return nil }
    (self.predelay, self.decay, self.size, self.diffusion, self.highCut) = (predelay, decay, size, diffusion, highCut)
    (self.lowCut, self.modulation, self.width, self.mix) = (lowCut, modulation, width, mix)
  }
}

/// The Reverb: a picture of how it decays, and its controls (its rooms are its presets).
struct ReverbView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let controls: ReverbControls

  @State private var hint: String?

  private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
  private let purple = Color(red: 0.68, green: 0.45, blue: 0.98)

  var body: some View {
    // Laid out for 900 × 360: help on top (the rooms are the header's presets), three
    // pictures, one row of knobs.
    VStack(spacing: 12) {
      HStack(spacing: 14) {
        Text(hint ?? "Point at a control to see what it does. Option-click a knob to reset it; double-click its value to type one.")
          .font(.system(size: 11))
          .foregroundStyle(hint == nil ? EffectStyle.label.opacity(0.6) : EffectStyle.label)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 28)
      HStack(spacing: 10) {
        // Canvases have no width of their own, so each gets one.
        EarlyGraph(controls: controls)
          .frame(width: 200)
        DecayGraph(controls: controls, tint: blue, highTint: purple)
          .frame(width: 404)
        ToneGraph(controls: controls, sampleRate: audioUnit.outputBusses[0].format.sampleRate, tint: blue)
          .frame(width: 248)
      }
      .frame(height: 140)
      HStack(spacing: 0) {
        knob(controls.predelay, "Predelay", "The gap before the reverb starts. A longer predelay keeps vocals and drums clear of their reverb.")
        knob(controls.decay, "Decay", "How long the reverb takes to die away (by 60 dB).")
        knob(controls.size, "Size", "How big the space is. Bigger spaces spread their early echoes further apart.")
        knob(controls.diffusion, "Diffusion",
          "How quickly the echoes blur into a smooth wash. Low: separate echoes, like a bare room. High: smooth and dense, like a plate.")
        knob(controls.highCut, "High Cut", "Darkens the reverb: cuts its highs, and makes them die away sooner.")
        knob(controls.lowCut, "Low Cut", "Thins the reverb: cuts its lows (24 dB per octave) so it doesn't muddy the bass.")
        knob(controls.modulation, "Modulation",
          "Gently wobbles the echoes, smoothing out metallic ringing. Higher settings add a chorus-like shimmer.")
        knob(controls.width, "Width", "How wide the reverb spreads across the stereo field. 0 % is mono.")
        knob(controls.mix, "Mix", "How much reverb against the dry sound. Use 100 % when the reverb is on an aux send.", tint: blue)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(EffectStyle.background)
    .environment(\.colorScheme, .dark)
  }

  private func knob(_ parameter: ObservableAUParameter, _ name: String, _ help: String, tint: Color? = nil) -> some View {
    Knob(parameter: parameter, name: name, tint: tint ?? purple, diameter: 50)
      .frame(maxWidth: .infinity)
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
  }
}

/// How the reverb dies away: silence for the predelay, a build-up through the early
/// echoes, then the tail falling 60 dB over the decay time, with the highs falling sooner
/// the lower the high cut.
private struct DecayGraph: View {
  let controls: ReverbControls
  let tint: Color
  let highTint: Color

  private static let floor: Float = -60

  var body: some View {
    let predelay = controls.predelay.value / 1_000
    let decay = controls.decay.value
    let highDecay = decay * min(1, powf(controls.highCut.value / 16_000, 0.6))
    let size = controls.size.value / 100
    let early = EarlyGraph.window(size: size)
    Canvas { context, size in
      let span = max(1, predelay + decay * 1.15)
      func x(_ seconds: Float) -> CGFloat { CGFloat(seconds / span) * size.width }
      func y(_ decibels: Float) -> CGFloat { CGFloat(decibels / Self.floor) * size.height }

      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      let step: Float = span > 6 ? 1 : 0.5
      for seconds in stride(from: step, to: span, by: step) {
        let position = x(seconds)
        context.stroke(Path { $0.move(to: CGPoint(x: position, y: 0)); $0.addLine(to: CGPoint(x: position, y: size.height)) },
          with: .color(EffectStyle.grid))
        guard position < size.width - 24 else { continue }
        context.draw(Text(String(format: seconds.rounded() == seconds ? "%.0f s" : "%.1f s", seconds))
            .font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: position + 2, y: size.height - 2), anchor: .bottomLeading)
      }
      for decibels in stride(from: Float(-12), to: Self.floor, by: -12) {
        let position = y(decibels)
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: position)); $0.addLine(to: CGPoint(x: size.width, y: position)) },
          with: .color(EffectStyle.grid))
      }

      // The tail grows through the early echoes, then falls in a straight line (in dB).
      func tail(decay: Float) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x(predelay), y: size.height))
        path.addLine(to: CGPoint(x: x(predelay + early), y: y(-3)))
        path.addLine(to: CGPoint(x: x(predelay + early + decay), y: y(Self.floor)))
        path.closeSubpath()
        return path
      }
      context.fill(tail(decay: decay), with: .linearGradient(
        Gradient(colors: [tint.opacity(0.6), tint.opacity(0.12)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      let highs = tail(decay: highDecay)
      context.fill(highs, with: .color(highTint.opacity(0.22)))
      context.stroke(highs, with: .color(highTint), lineWidth: 1.5)

      context.draw(Text("Lows and mids").font(.system(size: 9)).foregroundStyle(tint),
        at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
      context.draw(Text("Highs").font(.system(size: 9)).foregroundStyle(highTint),
        at: CGPoint(x: size.width - 6, y: 20), anchor: .topTrailing)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Decay")
    .accessibilityValue(String(format: "%.1f seconds", controls.decay.value))
  }
}

/// The first moments, zoomed in: the predelay, then the early echoes, spread out by the
/// size and blurred together (more of them, closer) by the diffusion.
private struct EarlyGraph: View {
  let controls: ReverbControls

  /// How long the early echoes take to arrive (15–80 ms, by size 0–1).
  static func window(size: Float) -> Float { 0.015 + 0.065 * size }

  var body: some View {
    let predelay = controls.predelay.value / 1_000
    let early = Self.window(size: controls.size.value / 100)
    let echoCount = 4 + Int(controls.diffusion.value / 100 * 24)
    // Show a little past the last echo.
    let span = max(0.1, ((predelay + early) * 1.25 / 0.05).rounded(.up) * 0.05)
    Canvas { context, size in
      func x(_ seconds: Float) -> CGFloat { CGFloat(seconds / span) * size.width }
      func y(_ decibels: Float) -> CGFloat { CGFloat(decibels / -30) * size.height }

      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      let step = span > 0.2 ? 100 : 50
      let ticks = Array(stride(from: step, to: Int(span * 1_000), by: step))
      for milliseconds in ticks {
        let position = x(Float(milliseconds) / 1_000)
        context.stroke(Path { $0.move(to: CGPoint(x: position, y: 0)); $0.addLine(to: CGPoint(x: position, y: size.height)) },
          with: .color(EffectStyle.grid))
      }
      // The predelay, shaded.
      context.fill(Path(CGRect(x: 0, y: 0, width: x(predelay), height: size.height)), with: .color(Color.white.opacity(0.04)))
      // The echoes (their heights vary, but the same way every time).
      for echo in 0..<echoCount {
        let fraction = Float(echo) / Float(max(1, echoCount - 1))
        let wobble = 0.5 + 0.5 * sin(Float(echo) * 2.39)
        let position = x(predelay + early * (0.05 + 0.95 * fraction))
        let level = -2 - 12 * fraction - 8 * wobble
        context.stroke(Path { $0.move(to: CGPoint(x: position, y: size.height)); $0.addLine(to: CGPoint(x: position, y: y(level))) },
          with: .color(Color.white.opacity(0.7)), lineWidth: 1)
      }
      // Time labels go on top of the echoes, on a dark backing so they stay readable.
      for milliseconds in ticks {
        let position = x(Float(milliseconds) / 1_000)
        guard position < size.width - 30 else { continue }
        let label = context.resolve(Text("\(milliseconds) ms").font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label))
        let labelSize = label.measure(in: size)
        let origin = CGPoint(x: position + 2, y: size.height - 2 - labelSize.height)
        context.fill(Path(roundedRect: CGRect(origin: origin, size: labelSize).insetBy(dx: -2, dy: -1), cornerRadius: 2),
          with: .color(.black.opacity(0.75)))
        context.draw(label, at: origin, anchor: .topLeading)
      }
      context.draw(Text("Early echoes").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.75)),
        at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Early echoes")
    .accessibilityValue("\(echoCount) echoes over \(Int(early * 1_000)) milliseconds")
  }
}

/// The reverb's tone: what the low and high cuts leave of it, 20 Hz to 20 kHz.
private struct ToneGraph: View {
  let controls: ReverbControls
  let sampleRate: Double
  let tint: Color

  private static let frequencies: [Float] = (0..<120).map { 20 * powf(1_000, Float($0) / 119) }

  var body: some View {
    let lowCut = controls.lowCut.value
    let highCut = controls.highCut.value
    let rate = sampleRate
    let decibels = Self.frequencies.map { OngakuReverbTone(lowCut, highCut, rate, $0) }
    Canvas { context, size in
      func x(_ frequency: Float) -> CGFloat { CGFloat(log10f(frequency / 20) / 3) * size.width }
      // 0 dB near the top, −36 dB at the bottom.
      func y(_ level: Float) -> CGFloat { size.height * 0.15 + CGFloat(-level / 36) * size.height * 0.85 }

      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      for (frequency, label) in [(Float(100), "100"), (1_000, "1k"), (10_000, "10k")] {
        let position = x(frequency)
        context.stroke(Path { $0.move(to: CGPoint(x: position, y: 0)); $0.addLine(to: CGPoint(x: position, y: size.height)) },
          with: .color(EffectStyle.grid))
        context.draw(Text(label).font(.system(size: 8)).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: position + 2, y: size.height - 2), anchor: .bottomLeading)
      }

      var curve = Path()
      for (index, (frequency, level)) in zip(Self.frequencies, decibels).enumerated() {
        let point = CGPoint(x: x(frequency), y: min(size.height, y(level)))
        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
      }
      var fill = curve
      fill.addLine(to: CGPoint(x: size.width, y: size.height))
      fill.addLine(to: CGPoint(x: 0, y: size.height))
      fill.closeSubpath()
      context.fill(fill, with: .color(tint.opacity(0.25)))
      context.stroke(curve, with: .color(tint), lineWidth: 1.5)

      context.draw(Text("Tone").font(.system(size: 9)).foregroundStyle(tint),
        at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Tone")
    .accessibilityValue("Low cut \(Int(controls.lowCut.value)) hertz, high cut \(Int(controls.highCut.value)) hertz")
  }
}
