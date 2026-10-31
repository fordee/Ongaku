//
//  CompressorView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Compressor's parameters.
@MainActor
struct CompressorControls {
  let threshold, ratio, attack, release, knee, makeUp, autoGain, mix, detection: ObservableAUParameter

  init?(_ tree: ObservableAUParameterGroup) {
    func parameter(_ identifier: String) -> ObservableAUParameter? {
      tree.children[identifier] as? ObservableAUParameter
    }
    guard let threshold = parameter("threshold"), let ratio = parameter("ratio"), let attack = parameter("attack"),
      let release = parameter("release"), let knee = parameter("knee"), let makeUp = parameter("makeUp"),
      let autoGain = parameter("autoGain"), let mix = parameter("mix"), let detection = parameter("detection")
    else { return nil }
    (self.threshold, self.ratio, self.attack, self.release, self.knee) = (threshold, ratio, attack, release, knee)
    (self.makeUp, self.autoGain, self.mix, self.detection) = (makeUp, autoGain, mix, detection)
  }

  /// The output level for an input level (dB), make-up gain included.
  func output(for input: Float) -> Float {
    let curve = OngakuCompressorCurve(input, threshold.value, ratio.value, knee.value)
    let auto = autoGain.boolValue ? -OngakuCompressorCurve(0, threshold.value, ratio.value, knee.value) / 2 : 0
    return curve + makeUp.value + auto
  }
}

/// Reads the Compressor's meters and lets them fall back smoothly.
@MainActor
final class CompressorMeters {
  private(set) var input: Float = -120
  private(set) var output: Float = -120
  private(set) var reduction: Float = 0
  private let audioUnit: OngakuEffectsAudioUnit

  init(audioUnit: OngakuEffectsAudioUnit) {
    self.audioUnit = audioUnit
  }

  func update() {
    input = max(OngakuMeterValue(audioUnit.meters, .inputPeak), input - 1.5)
    output = max(OngakuMeterValue(audioUnit.meters, .outputPeak), output - 1.5)
    reduction = min(OngakuMeterValue(audioUnit.meters, .gainReduction), reduction + 1)
  }
}

/// The Compressor: a gain reduction meter, its curve with the signal riding on it, and
/// its controls.
struct CompressorView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let controls: CompressorControls

  @State private var meters: CompressorMeters?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
      let _ = timeline.date
      let _ = meters?.update()
      HStack(alignment: .top, spacing: 22) {
        TransferCurve(controls: controls, input: meters?.input ?? -120)
          .frame(width: 230, height: 230)
        Grid(horizontalSpacing: 16, verticalSpacing: 18) {
          GridRow {
            Knob(parameter: controls.threshold, name: "Threshold", diameter: 56)
            Knob(parameter: controls.ratio, name: "Ratio", diameter: 56)
            Knob(parameter: controls.knee, name: "Knee", diameter: 56)
            Knob(parameter: controls.makeUp, name: "Make Up", tint: Color(red: 0.45, green: 0.8, blue: 0.4), diameter: 56)
          }
          GridRow {
            Knob(parameter: controls.attack, name: "Attack", diameter: 56)
            Knob(parameter: controls.release, name: "Release", diameter: 56)
            Knob(parameter: controls.mix, name: "Mix", tint: Color(red: 0.35, green: 0.6, blue: 0.98), diameter: 56)
            VStack(spacing: 10) {
              Toggle("Auto Gain", isOn: Binding(get: { controls.autoGain.boolValue }, set: { controls.autoGain.boolValue = $0 }))
                .toggleStyle(.button)
              Captioned(caption: "Detection") {
                Picker("Detection", selection: Binding(
                  get: { Int(controls.detection.value.rounded()) }, set: { controls.detection.value = AUValue($0) }
                )) {
                  Text("Peak").tag(0)
                  Text("RMS").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
              }
            }
            .controlSize(.small)
          }
        }
        HStack(spacing: 8) {
          LevelMeter(title: "In", level: meters?.input ?? -120)
          LevelMeter(title: "Out", level: meters?.output ?? -120)
        }
        .frame(height: 230)
      }
      // The meter spans the controls' width.
      .padding(.top, 52)
      .overlay(alignment: .top) { ReductionMeter(reduction: meters?.reduction ?? 0) }
      .fixedSize()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(EffectStyle.background)
    .environment(\.colorScheme, .dark)
    .onAppear {
      if meters == nil { meters = CompressorMeters(audioUnit: audioUnit) }
    }
  }
}

/// Gain reduction, filling from the right like Logic's: 0 at the right, −30 dB at the left.
struct ReductionMeter: View {
  let reduction: Float

  private static let range: Float = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Gain Reduction")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(EffectStyle.label)
      Canvas { context, size in
        let barHeight: CGFloat = 12
        func x(_ decibels: Float) -> CGFloat { size.width * CGFloat(1 + decibels / Self.range) }
        let bar = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(.black.opacity(0.55)))
        let reduced = min(Self.range, -reduction)
        if reduced > 0.05 {
          let filled = CGRect(x: x(-reduced), y: 0, width: size.width - x(-reduced), height: barHeight)
          context.fill(Path(roundedRect: filled, cornerRadius: 3), with: .linearGradient(
            Gradient(colors: [Color(red: 0.98, green: 0.35, blue: 0.2), Color(red: 0.98, green: 0.7, blue: 0.2)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
        }
        for mark: Float in [-30, -25, -20, -15, -10, -6, -3, 0] {
          let position = x(mark)
          context.stroke(Path { $0.move(to: CGPoint(x: position, y: barHeight)); $0.addLine(to: CGPoint(x: position, y: barHeight + 3)) },
            with: .color(EffectStyle.label))
          let anchor: UnitPoint = mark == -30 ? .topLeading : mark == 0 ? .topTrailing : .top
          context.draw(Text("\(Int(mark))").font(.system(size: 9).monospacedDigit()).foregroundStyle(EffectStyle.label),
            at: CGPoint(x: position, y: barHeight + 4), anchor: anchor)
        }
      }
      .frame(height: 28)
    }
    .accessibilityElement()
    .accessibilityLabel("Gain Reduction")
    .accessibilityValue(String(format: "%.1f dB", reduction))
  }
}

/// A vertical peak meter, −60 to 0 dB.
struct LevelMeter: View {
  let title: String
  let level: Float

  var body: some View {
    VStack(spacing: 3) {
      GeometryReader { geometry in
        let fraction = CGFloat(max(0, min(1, (level + 60) / 60)))
        ZStack(alignment: .bottom) {
          RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.55))
          RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(
              colors: [Color(red: 0.3, green: 0.85, blue: 0.4), Color(red: 0.95, green: 0.85, blue: 0.25), Color(red: 0.95, green: 0.3, blue: 0.25)],
              startPoint: .bottom, endPoint: .top))
            .frame(height: geometry.size.height * fraction)
        }
      }
      .frame(width: 10)
      Text(title)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(EffectStyle.label)
    }
    .accessibilityElement()
    .accessibilityLabel("\(title) Level")
    .accessibilityValue(String(format: "%.0f dB", level))
  }
}

/// Input level across, output level up: the compressor's curve, the threshold, and a dot
/// riding the curve at the current input level.
private struct TransferCurve: View {
  let controls: CompressorControls
  let input: Float

  private static let floor: Float = -60

  var body: some View {
    Canvas { context, size in
      func point(_ input: Float, _ output: Float) -> CGPoint {
        CGPoint(
          x: CGFloat((input - Self.floor) / -Self.floor) * size.width,
          y: size.height - CGFloat((min(output, 6) - Self.floor) / -Self.floor) * size.height)
      }
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      for decibels in stride(from: Self.floor + 10, to: 0, by: 10) {
        let position = point(decibels, decibels)
        context.stroke(Path { $0.move(to: CGPoint(x: position.x, y: 0)); $0.addLine(to: CGPoint(x: position.x, y: size.height)) },
          with: .color(EffectStyle.grid))
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: position.y)); $0.addLine(to: CGPoint(x: size.width, y: position.y)) },
          with: .color(EffectStyle.grid))
      }
      for decibels: Float in [-48, -36, -24, -12] {
        context.draw(Text("\(Int(decibels))").font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: point(decibels, 0).x, y: size.height - 3), anchor: .bottom)
        context.draw(Text("\(Int(decibels))").font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: 3, y: point(0, decibels).y), anchor: .leading)
      }
      // Unity, for reference.
      context.stroke(Path { $0.move(to: point(Self.floor, Self.floor)); $0.addLine(to: point(0, 0)) },
        with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

      let threshold = point(controls.threshold.value, Self.floor).x
      context.stroke(Path { $0.move(to: CGPoint(x: threshold, y: 0)); $0.addLine(to: CGPoint(x: threshold, y: size.height)) },
        with: .color(Color(red: 0.98, green: 0.62, blue: 0.2).opacity(0.5)))

      var curve = Path()
      for step in 0...120 {
        let level = Self.floor + Float(step) / 2
        let position = point(level, controls.output(for: level))
        if step == 0 { curve.move(to: position) } else { curve.addLine(to: position) }
      }
      context.stroke(curve, with: .color(Color(white: 0.95)), lineWidth: 2)

      if input > Self.floor {
        let level = min(0, input)
        let dot = point(level, controls.output(for: level))
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)),
          with: .color(Color(red: 0.98, green: 0.62, blue: 0.2)))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Compressor curve")
  }
}
