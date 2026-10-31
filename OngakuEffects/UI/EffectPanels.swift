//
//  EffectPanels.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The frame the effects share: a line explaining whatever's pointed at, then the effect's
/// own pictures and controls, on the dark panel. (Presets are in the window's header.)
struct EffectPanel<Content: View>: View {
  let audioUnit: OngakuEffectsAudioUnit
  @Binding var hint: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 14) {
        Text(hint ?? "Point at a control to see what it does. Option-click a knob to reset it; double-click its value to type one.")
          .font(.system(size: 11))
          .foregroundStyle(hint == nil ? EffectStyle.label.opacity(0.6) : EffectStyle.label)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 28)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(EffectStyle.background)
    .environment(\.colorScheme, .dark)
  }
}

/// Looks up an effect's parameters by identifier.
@MainActor
struct EffectParameters {
  let tree: ObservableAUParameterGroup

  subscript(identifier: String) -> ObservableAUParameter? {
    tree.children[identifier] as? ObservableAUParameter
  }

  func value(_ identifier: String) -> Float {
    self[identifier]?.value ?? 0
  }
}

/// A knob that says what it does in the hint line when it's pointed at (Option-click it to
/// reset it; double-click its value to type one).
struct HintKnob: View {
  let parameter: ObservableAUParameter?
  let name: String
  let help: String
  @Binding var hint: String?
  var tint: Color = Color(red: 0.98, green: 0.62, blue: 0.2)
  var diameter: CGFloat = 50

  var body: some View {
    if let parameter {
      Knob(parameter: parameter, name: name, tint: tint, diameter: diameter)
        .help(help)
        .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
        .frame(maxWidth: .infinity)
    }
  }
}

/// An on/off parameter as a lit button.
struct ParameterToggle: View {
  let parameter: ObservableAUParameter?
  let title: String
  let help: String
  @Binding var hint: String?

  var body: some View {
    if let parameter {
      Toggle(title, isOn: Binding(get: { parameter.boolValue }, set: { parameter.boolValue = $0 }))
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
        .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
    }
  }
}

/// A choice between a few values, as a segmented control.
struct ParameterPicker: View {
  let parameter: ObservableAUParameter?
  let options: [String]
  let help: String
  @Binding var hint: String?

  var body: some View {
    if let parameter {
      Picker("", selection: Binding(get: { Int(parameter.value.rounded()) }, set: { parameter.value = AUValue($0) })) {
        ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
    }
  }
}

/// An effect's meters, read from the Audio Unit and falling back smoothly, with the last
/// few seconds of the input level and gain reduction for history graphs.
@MainActor
final class EffectMeters {
  private(set) var input: Float = -120
  private(set) var output: Float = -120
  private(set) var reduction: Float = 0
  private(set) var inputHistory: [Float] = []
  private(set) var reductionHistory: [Float] = []
  private let audioUnit: OngakuEffectsAudioUnit
  static let historyLength = 180

  init(audioUnit: OngakuEffectsAudioUnit) {
    self.audioUnit = audioUnit
  }

  func update() {
    let peakIn = OngakuMeterValue(audioUnit.meters, .inputPeak)
    input = max(peakIn, input - 1.5)
    output = max(OngakuMeterValue(audioUnit.meters, .outputPeak), output - 1.5)
    let latestReduction = OngakuMeterValue(audioUnit.meters, .gainReduction)
    reduction = min(latestReduction, reduction + 1)
    inputHistory.append(peakIn)
    reductionHistory.append(latestReduction)
    if inputHistory.count > Self.historyLength { inputHistory.removeFirst(inputHistory.count - Self.historyLength) }
    if reductionHistory.count > Self.historyLength {
      reductionHistory.removeFirst(reductionHistory.count - Self.historyLength)
    }
  }

  /// Another of the Audio Unit's meters.
  func value(_ meter: OngakuMeter) -> Float {
    OngakuMeterValue(audioUnit.meters, meter)
  }
}

/// The last few seconds, scrolling left: the input level as a filled area, the threshold
/// as a line across, and the gain reduction hanging down from the top.
struct HistoryGraph: View {
  let input: [Float]
  let reduction: [Float]
  var threshold: Float?
  var tint: Color = Color(red: 0.35, green: 0.6, blue: 0.98)

  private static let floor: Float = -72

  var body: some View {
    let (input, reduction, threshold, tint) = (input, reduction, threshold, tint)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      func y(_ decibels: Float) -> CGFloat { size.height * CGFloat(min(1, max(0, decibels / Self.floor))) }
      for decibels: Float in [-12, -24, -36, -48, -60] {
        let line = y(decibels)
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: line)); $0.addLine(to: CGPoint(x: size.width, y: line)) },
          with: .color(EffectStyle.grid))
        context.draw(Text("\(Int(decibels))").font(.system(size: 8).monospacedDigit()).foregroundStyle(EffectStyle.label),
          at: CGPoint(x: 3, y: line - 1), anchor: .bottomLeading)
      }
      let step = size.width / CGFloat(EffectMeters.historyLength - 1)
      let offset = CGFloat(EffectMeters.historyLength - input.count) * step
      if input.count > 1 {
        var area = Path()
        area.move(to: CGPoint(x: offset, y: size.height))
        for (index, level) in input.enumerated() {
          area.addLine(to: CGPoint(x: offset + CGFloat(index) * step, y: y(level)))
        }
        area.addLine(to: CGPoint(x: offset + CGFloat(input.count - 1) * step, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.55), tint.opacity(0.12)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      }
      if reduction.count > 1 {
        var line = Path()
        for (index, amount) in reduction.enumerated() {
          let point = CGPoint(x: offset + CGFloat(index) * step, y: y(min(0, amount)))
          if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(Color(red: 0.98, green: 0.4, blue: 0.25)), lineWidth: 1.6)
      }
      if let threshold {
        let line = y(threshold)
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: line)); $0.addLine(to: CGPoint(x: size.width, y: line)) },
          with: .color(Color(red: 0.98, green: 0.62, blue: 0.2)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Level history")
  }
}

/// Input and output meters side by side.
struct InOutMeters: View {
  let meters: EffectMeters?

  var body: some View {
    HStack(spacing: 8) {
      LevelMeter(title: "In", level: meters?.input ?? -120)
      LevelMeter(title: "Out", level: meters?.output ?? -120)
    }
  }
}
