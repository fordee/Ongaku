//
//  DelayView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Delay's parameters.
@MainActor
struct DelayControls {
  let sync, time, note, feedback, pingPong, lowCut, highCut, flutter, drive, mix: ObservableAUParameter

  init?(_ tree: ObservableAUParameterGroup) {
    func parameter(_ identifier: String) -> ObservableAUParameter? {
      tree.children[identifier] as? ObservableAUParameter
    }
    guard let sync = parameter("sync"), let time = parameter("time"), let note = parameter("note"),
      let feedback = parameter("feedback"), let pingPong = parameter("pingPong"), let lowCut = parameter("lowCut"),
      let highCut = parameter("highCut"), let flutter = parameter("flutter"), let drive = parameter("drive"),
      let mix = parameter("mix")
    else { return nil }
    (self.sync, self.time, self.note, self.feedback, self.pingPong) = (sync, time, note, feedback, pingPong)
    (self.lowCut, self.highCut, self.flutter, self.drive, self.mix) = (lowCut, highCut, flutter, drive, mix)
  }

  /// The delay time in seconds at `tempo`.
  func seconds(tempo: Double) -> Double {
    if sync.boolValue {
      let index = min(DelayParameters.noteBeats.count - 1, max(0, Int(note.value.rounded())))
      return DelayParameters.noteBeats[index] * 60 / max(20, tempo)
    }
    return Double(time.value) / 1_000
  }
}

/// The Delay: its echoes laid out in time over the song's beats, and its controls.
struct DelayView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let controls: DelayControls

  @State private var hint: String?

  private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
  private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)

  var body: some View {
    // Laid out for 900 × 340: switches and help on top, the echoes, one row of knobs.
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
      let heard = OngakuMeterValue(audioUnit.meters, .tempo)
      let tempo = heard > 0 ? Double(heard) : 120
      VStack(spacing: 12) {
        HStack(spacing: 10) {
          toggle(controls.sync, "Sync", "Times the echoes in notes at the song's tempo, instead of in milliseconds.")
          toggle(controls.pingPong, "Ping-Pong", "Bounces the echoes from side to side.")
          Text(hint ?? "Point at a control to see what it does.")
            .font(.system(size: 11))
            .foregroundStyle(hint == nil ? EffectStyle.label.opacity(0.6) : EffectStyle.label)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(String(format: "%.1f BPM", tempo))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(EffectStyle.label)
            .help("The song's tempo, which synced echoes follow.")
        }
        .controlSize(.small)
        .frame(height: 24)
        EchoGraph(controls: controls, tempo: tempo, left: blue, right: orange)
          .frame(width: 872, height: 130)
        HStack(spacing: 0) {
          if controls.sync.boolValue {
            knob(controls.note, "Note", "The time between echoes, as a note at the song's tempo. T is a triplet, a dot is half as long again.")
          } else {
            knob(controls.time, "Time", "The time between echoes, in milliseconds.")
          }
          knob(controls.feedback, "Feedback", "How much of each echo comes back as another. Higher settings repeat for longer.")
          knob(controls.lowCut, "Low Cut", "Thins the echoes, a little more with every repeat.")
          knob(controls.highCut, "High Cut", "Darkens the echoes, a little more with every repeat, like tape.")
          knob(controls.flutter, "Wow & Flutter", "Wobbles the echoes' timing (and so their pitch) like a tape machine.")
          knob(controls.drive, "Drive", "Saturates loud echoes softly, like tape pushed hard.")
          knob(controls.mix, "Mix", "How much of the echoes against the dry sound. Use 100 % when the delay is on an aux send.", tint: blue)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(EffectStyle.background)
    .environment(\.colorScheme, .dark)
  }

  private func knob(_ parameter: ObservableAUParameter, _ name: String, _ help: String, tint: Color? = nil) -> some View {
    Knob(parameter: parameter, name: name, tint: tint ?? orange, diameter: 50)
      .frame(maxWidth: .infinity)
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
  }

  private func toggle(_ parameter: ObservableAUParameter, _ name: String, _ help: String) -> some View {
    Toggle(name, isOn: Binding(get: { parameter.boolValue }, set: { parameter.boolValue = $0 }))
      .toggleStyle(.button)
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
  }
}

/// The dry sound, then each echo as a bar: spaced by the delay time, falling by the
/// feedback, alternating sides in ping-pong mode. Beats are marked behind them.
private struct EchoGraph: View {
  let controls: DelayControls
  let tempo: Double
  let left: Color
  let right: Color

  private static let floor = -48.0

  var body: some View {
    let delay = controls.seconds(tempo: tempo)
    let feedback = Double(controls.feedback.value) / 100
    let pingPong = controls.pingPong.boolValue
    // Echoes until they're 48 dB down (at most 24; at full feedback they never fade), and at
    // least two seconds shown. The count is worked out in floating point and clamped before
    // it becomes an integer, since it's infinite at 100 %.
    let fading = feedback > 0.01 ? Self.floor / (20 * log10(min(feedback, 0.999))) : 1
    let repeats = Int(min(24, max(1, fading.rounded(.up))))
    let span = max(2, delay * Double(repeats + 1) * 1.05)
    let beat = 60 / max(20, tempo)
    Canvas { context, size in
      func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / span) * (size.width - 12) + 6 }
      func height(_ decibels: Double) -> CGFloat { CGFloat(max(0, 1 - decibels / Self.floor)) * (size.height - 22) }

      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      // Beats (and bars of four, brighter).
      var index = 0
      for seconds in stride(from: 0.0, through: span, by: beat) {
        let position = x(seconds)
        let isBar = index % 4 == 0
        context.stroke(Path { $0.move(to: CGPoint(x: position, y: 0)); $0.addLine(to: CGPoint(x: position, y: size.height)) },
          with: .color(isBar ? EffectStyle.grid.opacity(2) : EffectStyle.grid))
        if isBar, index > 0, position < size.width - 30 {
          context.draw(Text("\(index / 4 + 1)").font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
            at: CGPoint(x: position + 3, y: size.height - 2), anchor: .bottomLeading)
        }
        index += 1
      }

      // The dry hit.
      let bottom = size.height - 14
      context.fill(Path(CGRect(x: x(0) - 2, y: bottom - height(0), width: 4, height: height(0))), with: .color(.white.opacity(0.85)))
      // The echoes.
      for echo in 1...repeats {
        let decibels = 20 * log10(max(1e-6, pow(feedback, Double(echo - 1))))
        guard decibels > Self.floor else { break }
        let color = pingPong ? (echo % 2 == 1 ? left : right) : left.mix(with: right, by: 0.5)
        let barHeight = height(decibels)
        context.fill(Path(roundedRect: CGRect(x: x(delay * Double(echo)) - 3, y: bottom - barHeight, width: 6, height: barHeight),
          cornerRadius: 2), with: .color(color))
      }

      context.draw(Text(pingPong ? "Left" : "Echoes").font(.system(size: 9)).foregroundStyle(pingPong ? left : left.mix(with: right, by: 0.5)),
        at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
      if pingPong {
        context.draw(Text("Right").font(.system(size: 9)).foregroundStyle(right),
          at: CGPoint(x: size.width - 6, y: 20), anchor: .topTrailing)
      }
      context.draw(Text(String(format: delay < 1 ? "%.0f ms" : "%.2f s", delay < 1 ? delay * 1_000 : delay))
          .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(EffectStyle.value),
        at: CGPoint(x: 8, y: 6), anchor: .topLeading)
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Echoes")
    .accessibilityValue(String(format: "%.0f milliseconds apart, %d heard", delay * 1_000, repeats))
  }
}
