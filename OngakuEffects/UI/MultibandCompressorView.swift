//
//  MultibandCompressorView.swift
//  OngakuEffects
//

import SwiftUI

private let bandColors = [
  Color(red: 0.68, green: 0.45, blue: 0.98), Color(red: 0.98, green: 0.62, blue: 0.2), Color(red: 0.35, green: 0.6, blue: 0.98),
]
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)

/// The Multiband Compressor: the three bands across the frequencies, each dipping by how
/// much it's being turned down, then each band's controls and the shared ones.
struct MultibandCompressorView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 860 × 480.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        let reductions = (0..<3).map { Double(meters?.value(OngakuMeter(rawValue: OngakuMeter.firstBandReduction.rawValue + Int32($0))!) ?? 0) }
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            BandsPicture(
              lowCrossover: Double(parameters.value("lowCrossover")), highCrossover: Double(parameters.value("highCrossover")),
              reductions: reductions)
            InOutMeters(meters: meters)
          }
          .frame(height: 120)
          HStack(alignment: .top, spacing: 10) {
            ForEach(0..<3, id: \.self) { band in
              BandColumn(band: band, parameters: parameters, reduction: reductions[band], hint: $hint)
            }
          }
          // The settings the bands share.
          HStack(spacing: 0) {
            HintKnob(parameter: parameters["lowCrossover"], name: "Low Crossover",
              help: "Where the low band ends and the mid band starts.", hint: $hint, tint: bandColors[0], diameter: 40)
            HintKnob(parameter: parameters["highCrossover"], name: "High Crossover",
              help: "Where the mid band ends and the high band starts.", hint: $hint, tint: bandColors[2], diameter: 40)
            HintKnob(parameter: parameters["attack"], name: "Attack",
              help: "How quickly a band is turned down when it gets loud. Slower lets the start of a hit through.",
              hint: $hint, diameter: 40)
            HintKnob(parameter: parameters["release"], name: "Release",
              help: "How quickly a band comes back up afterwards.", hint: $hint, diameter: 40)
            HintKnob(parameter: parameters["output"], name: "Output", help: "The level out.", hint: $hint, tint: green, diameter: 40)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

/// One band's name, how much it's being turned down, and its threshold, ratio and make-up.
private struct BandColumn: View {
  let band: Int
  let parameters: EffectParameters
  let reduction: Double
  @Binding var hint: String?

  var body: some View {
    let name = MultibandParameters.bandNames[band]
    VStack(spacing: 4) {
      HStack(spacing: 6) {
        Text(name).font(.system(size: 11, weight: .bold)).foregroundStyle(bandColors[band])
        Text(String(format: "%.1f dB", reduction)).font(.system(size: 10, weight: .medium).monospacedDigit())
          .foregroundStyle(EffectStyle.label)
      }
      HStack(spacing: 0) {
        HintKnob(parameter: parameters["threshold\(band)"], name: "Threshold",
          help: "Above this, the \(name.lowercased()) band is turned down.", hint: $hint, tint: bandColors[band], diameter: 40)
        HintKnob(parameter: parameters["ratio\(band)"], name: "Ratio",
          help: "How firmly: 2 : 1 is gentle, 8 : 1 holds it right down.", hint: $hint, tint: bandColors[band], diameter: 40)
        HintKnob(parameter: parameters["makeUp\(band)"], name: "Make-Up",
          help: "Turns the \(name.lowercased()) band back up (or down) after compressing.", hint: $hint, tint: green, diameter: 40)
      }
    }
    .padding(.vertical, 6)
    .background(bandColors[band].opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(name) band")
  }
}

/// The frequencies from 20 Hz to 20 kHz, the three bands in their colours, each band's top
/// pushed down by its gain reduction.
private struct BandsPicture: View {
  let lowCrossover: Double
  let highCrossover: Double
  let reductions: [Double]

  var body: some View {
    let (lowCrossover, highCrossover, reductions) = (lowCrossover, highCrossover, reductions)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      func x(_ frequency: Double) -> CGFloat {
        CGFloat(log10(frequency / 20) / 3) * size.width
      }
      for frequency in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
        context.stroke(Path { $0.move(to: CGPoint(x: x(frequency), y: 0)); $0.addLine(to: CGPoint(x: x(frequency), y: size.height - 14)) },
          with: .color(EffectStyle.grid))
        context.draw(Text(frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))")
          .font(.system(size: 8.5)).foregroundStyle(EffectStyle.label.opacity(0.7)), at: CGPoint(x: x(frequency), y: size.height - 6))
      }
      let edges = [20, lowCrossover, max(highCrossover, lowCrossover * 2), 20_000]
      // 0 dB of reduction at the top; 24 dB fills the band to the floor.
      let floor = size.height - 16
      for band in 0..<3 {
        let left = x(edges[band]), right = x(edges[band + 1])
        let depth = CGFloat(min(24, max(0, -reductions[band])) / 24) * (floor - 18)
        let rect = CGRect(x: left + 1, y: 18 + depth, width: max(0, right - left - 2), height: max(0, floor - 18 - depth))
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(bandColors[band].opacity(0.35)))
        context.stroke(Path { $0.move(to: CGPoint(x: left + 1, y: 18 + depth)); $0.addLine(to: CGPoint(x: right - 1, y: 18 + depth)) },
          with: .color(bandColors[band]), lineWidth: 2)
        context.draw(Text(MultibandParameters.bandNames[band]).font(.system(size: 10, weight: .bold)).foregroundStyle(bandColors[band]),
          at: CGPoint(x: (left + right) / 2, y: 9))
      }
      for edge in edges.dropFirst().dropLast() {
        context.stroke(Path { $0.move(to: CGPoint(x: x(edge), y: 0)); $0.addLine(to: CGPoint(x: x(edge), y: floor)) },
          with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Bands")
    .accessibilityValue(zip(MultibandParameters.bandNames, reductions).map { "\($0) \(Int($1.rounded())) dB" }.joined(separator: ", "))
  }
}

#Preview("Multiband Compressor") {
  PluginPreview(effect: .multibandCompressor) { audioUnit in
    for (band, reduction) in [Float(-6), -2.5, -4].enumerated() {
      audioUnit.meters[Int(OngakuMeter.firstBandReduction.rawValue) + band] = reduction
    }
  }
}
