//
//  ChannelEQView.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The Channel EQ's parameters, band by band.
@MainActor
struct EQControls {
  @MainActor
  struct Band: Identifiable {
    let id: Int
    let spec: ChannelEQParameters.Band
    let on: ObservableAUParameter
    let frequency: ObservableAUParameter
    let q: ObservableAUParameter
    /// Bells and shelves have a gain; the cuts have a slope instead.
    let gain: ObservableAUParameter?
    let slope: ObservableAUParameter?

    var isOn: Bool { on.value >= 0.5 }
    var color: Color { EQControls.colors[id] }
  }

  static let colors: [Color] = [
    Color(red: 0.95, green: 0.3, blue: 0.3), Color(red: 0.98, green: 0.55, blue: 0.2),
    Color(red: 0.95, green: 0.82, blue: 0.25), Color(red: 0.45, green: 0.85, blue: 0.35),
    Color(red: 0.3, green: 0.82, blue: 0.85), Color(red: 0.35, green: 0.55, blue: 0.98),
    Color(red: 0.62, green: 0.42, blue: 0.95), Color(red: 0.92, green: 0.38, blue: 0.8),
  ]

  let outputGain: ObservableAUParameter
  let bands: [Band]

  init?(_ tree: ObservableAUParameterGroup) {
    guard let outputGain = tree.children["outputGain"] as? ObservableAUParameter else { return nil }
    var bands: [Band] = []
    for (index, spec) in ChannelEQParameters.bands.enumerated() {
      guard let group = tree.children[spec.identifier] as? ObservableAUParameterGroup,
        let on = group.children["on"] as? ObservableAUParameter,
        let frequency = group.children["frequency"] as? ObservableAUParameter,
        let q = group.children["q"] as? ObservableAUParameter
      else { return nil }
      bands.append(Band(
        id: index, spec: spec, on: on, frequency: frequency, q: q,
        gain: group.children["gain"] as? ObservableAUParameter, slope: group.children["slope"] as? ObservableAUParameter))
    }
    self.outputGain = outputGain
    self.bands = bands
  }

  /// Every parameter's value, indexed by address, as the C++ response function wants them.
  /// `only` keeps just one band (and no output gain), for drawing that band's own curve.
  func values(only: Int? = nil) -> [Float] {
    var values = [Float](repeating: 0, count: Int(OngakuEffectsParameterAddress.eqFirstBand.rawValue) + 8 * Int(OngakuEQBandStride))
    values[Int(OngakuEffectsParameterAddress.eqOutputGain.rawValue)] = only == nil ? outputGain.value : 0
    for band in bands {
      let isIncluded = only == nil || only == band.id
      values[address(band.id, .on)] = isIncluded ? band.on.value : 0
      values[address(band.id, .frequency)] = band.frequency.value
      values[address(band.id, .Q)] = band.q.value
      values[address(band.id, .gain)] = band.gain?.value ?? 0
      values[address(band.id, .slope)] = band.slope?.value ?? 1
    }
    return values
  }

  private func address(_ band: Int, _ field: OngakuEQBandField) -> Int {
    Int(ChannelEQParameters.address(band: band, field))
  }

  /// The EQ's gain in decibels at each frequency.
  static func response(_ values: [Float], sampleRate: Double, at frequencies: [Float]) -> [Float] {
    var decibels = [Float](repeating: 0, count: frequencies.count)
    values.withUnsafeBufferPointer { values in
      frequencies.withUnsafeBufferPointer { frequencies in
        decibels.withUnsafeMutableBufferPointer { decibels in
          OngakuChannelEQResponse(
            values.baseAddress, sampleRate, frequencies.baseAddress, decibels.baseAddress, Int32(frequencies.count))
        }
      }
    }
    return decibels
  }
}

/// The Channel EQ: its curve over a live spectrum, with a handle for each band, and the
/// bands' settings underneath.
struct ChannelEQView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let controls: EQControls

  @State private var analyser: SpectrumAnalyser?
  @State private var showsAnalyser = true

  var body: some View {
    VStack(spacing: 8) {
      EQGraph(controls: controls, sampleRate: audioUnit.outputBusses[0].format.sampleRate, analyser: showsAnalyser ? analyser : nil)
        .clipShape(RoundedRectangle(cornerRadius: 4))
      HStack(alignment: .top, spacing: 6) {
        VStack(spacing: 6) {
          Toggle("Analyzer", isOn: $showsAnalyser)
            .toggleStyle(.button)
            .controlSize(.small)
          Captioned(caption: "Gain") { DragValue(parameter: controls.outputGain) }
        }
        .frame(width: 74)
        ForEach(controls.bands) { band in
          EQBandColumn(band: band)
        }
      }
    }
    .padding(10)
    .background(EffectStyle.background)
    .environment(\.colorScheme, .dark)
    .onAppear {
      if analyser == nil { analyser = SpectrumAnalyser(audioUnit: audioUnit) }
    }
  }
}

/// One band's switch and settings.
private struct EQBandColumn: View {
  let band: EQControls.Band

  var body: some View {
    VStack(spacing: 4) {
      Button {
        band.on.value = band.isOn ? 0 : 1
      } label: {
        Text(band.spec.name)
          .font(.system(size: 10, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 18)
          .foregroundStyle(band.isOn ? Color.black : EffectStyle.label)
          .background(RoundedRectangle(cornerRadius: 3).fill(band.isOn ? band.color : Color.white.opacity(0.06)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(band.spec.name) On")
      .accessibilityValue(band.isOn ? "On" : "Off")
      Captioned(caption: "Frequency") { DragValue(parameter: band.frequency, tint: band.isOn ? band.color : EffectStyle.label) }
      if let gain = band.gain {
        Captioned(caption: "Gain") { DragValue(parameter: gain) }
      }
      if let slope = band.slope {
        Captioned(caption: "Slope") {
          Picker("Slope", selection: Binding(get: { Int(slope.value.rounded()) }, set: { slope.value = AUValue($0) })) {
            ForEach(ChannelEQParameters.slopes.indices, id: \.self) { index in
              Text(ChannelEQParameters.slopes[index]).tag(index)
            }
          }
          .labelsHidden()
          .controlSize(.mini)
        }
      }
      Captioned(caption: "Q") { DragValue(parameter: band.q) }
    }
    .frame(maxWidth: .infinity)
    .opacity(band.isOn ? 1 : 0.6)
  }
}

/// The curve, the spectrum behind it and the band handles, which drag frequency
/// (sideways) and gain (up and down).
private struct EQGraph: View {
  let controls: EQControls
  let sampleRate: Double
  let analyser: SpectrumAnalyser?

  @State private var dragged: Int?

  private static let maxDecibels: Float = 24
  private static let frequencies: [Float] = (0..<256).map { 20 * powf(1_000, Float($0) / 255) }

  var body: some View {
    GeometryReader { geometry in
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: analyser == nil)) { timeline in
        let levels = spectrum(at: timeline.date)
        Canvas { context, size in
          draw(in: &context, size: size, levels: levels)
        }
      }
      .contentShape(Rectangle())
      .gesture(dragGesture(size: geometry.size))
      .accessibilityElement()
      .accessibilityLabel("EQ curve")
    }
    .frame(minHeight: 220)
    .background(Color.black.opacity(0.55))
  }

  private func spectrum(at date: Date) -> [Float]? {
    guard let analyser else { return nil }
    analyser.update()
    return analyser.levels
  }

  // MARK: Geometry

  private func x(_ frequency: Float, width: CGFloat) -> CGFloat {
    CGFloat(log10f(frequency / 20) / 3) * width
  }

  private func frequency(atX x: CGFloat, width: CGFloat) -> Float {
    20 * powf(1_000, Float(x / width))
  }

  private func y(_ decibels: Float, height: CGFloat) -> CGFloat {
    height / 2 - CGFloat(decibels / Self.maxDecibels) * height * 0.45
  }

  private func decibels(atY y: CGFloat, height: CGFloat) -> Float {
    Float((height / 2 - y) / (height * 0.45)) * Self.maxDecibels
  }

  private func handlePoint(_ band: EQControls.Band, size: CGSize) -> CGPoint {
    let frequency = band.frequency.value
    let gain: Float = band.gain.map { band.isOn ? $0.value : 0 }
      ?? EQControls.response(controls.values(only: band.id), sampleRate: sampleRate, at: [frequency])[0]
    return CGPoint(x: x(frequency, width: size.width), y: y(max(-Self.maxDecibels, gain), height: size.height))
  }

  // MARK: Drawing

  private func draw(in context: inout GraphicsContext, size: CGSize, levels: [Float]?) {
    drawGrid(in: &context, size: size)

    if let levels, let analyser {
      var path = Path()
      path.move(to: CGPoint(x: 0, y: size.height))
      for (frequency, level) in zip(analyser.frequencies, levels) {
        let height = CGFloat((level - SpectrumAnalyser.floor) / -SpectrumAnalyser.floor) * size.height
        path.addLine(to: CGPoint(x: x(frequency, width: size.width), y: size.height - height))
      }
      path.addLine(to: CGPoint(x: size.width, y: size.height))
      path.closeSubpath()
      context.fill(path, with: .linearGradient(
        Gradient(colors: [Color(red: 0.3, green: 0.6, blue: 1).opacity(0.45), Color(red: 0.3, green: 0.6, blue: 1).opacity(0.1)]),
        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    // Each band's own curve, shaded in its colour.
    let zero = y(0, height: size.height)
    for band in controls.bands where band.isOn && (band.gain.map { abs($0.value) > 0.05 } ?? true) {
      let response = EQControls.response(controls.values(only: band.id), sampleRate: sampleRate, at: Self.frequencies)
      var path = curve(response, size: size)
      path.addLine(to: CGPoint(x: size.width, y: zero))
      path.addLine(to: CGPoint(x: 0, y: zero))
      path.closeSubpath()
      context.fill(path, with: .color(band.color.opacity(0.16)))
    }

    let total = EQControls.response(controls.values(), sampleRate: sampleRate, at: Self.frequencies)
    context.stroke(curve(total, size: size), with: .color(Color(white: 0.95)), lineWidth: 2)

    for band in controls.bands {
      let point = handlePoint(band, size: size)
      let radius: CGFloat = dragged == band.id ? 8 : 6.5
      let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
      context.fill(circle, with: .color(band.isOn ? band.color : Color(white: 0.4)))
      context.stroke(circle, with: .color(.black.opacity(0.6)), lineWidth: 1)
    }
  }

  private func curve(_ decibels: [Float], size: CGSize) -> Path {
    var path = Path()
    for (index, (frequency, level)) in zip(Self.frequencies, decibels).enumerated() {
      let clamped = min(Self.maxDecibels * 1.1, max(-Self.maxDecibels * 1.1, level))
      let point = CGPoint(x: x(frequency, width: size.width), y: y(clamped, height: size.height))
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }

  private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
    let labels: [(Float, String)] = [
      (50, "50"), (100, "100"), (200, "200"), (500, "500"), (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"),
    ]
    for (frequency, label) in labels {
      let position = x(frequency, width: size.width)
      context.stroke(Path { $0.move(to: CGPoint(x: position, y: 0)); $0.addLine(to: CGPoint(x: position, y: size.height)) },
        with: .color(EffectStyle.grid))
      context.draw(Text(label).font(.system(size: 9)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: position + 3, y: size.height - 8), anchor: .leading)
    }
    for decibels in stride(from: -18, through: 18, by: 6) {
      let position = y(Float(decibels), height: size.height)
      context.stroke(Path { $0.move(to: CGPoint(x: 0, y: position)); $0.addLine(to: CGPoint(x: size.width, y: position)) },
        with: .color(decibels == 0 ? EffectStyle.grid.opacity(2.5) : EffectStyle.grid))
      context.draw(Text(decibels > 0 ? "+\(decibels)" : "\(decibels)").font(.system(size: 9)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: 4, y: position - 6), anchor: .leading)
    }
  }

  // MARK: Dragging

  private func dragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { drag in
        if dragged == nil {
          // Pick up the nearest handle, if the drag started on or near one.
          let nearest = controls.bands.min { first, second in
            distance(handlePoint(first, size: size), drag.startLocation) < distance(handlePoint(second, size: size), drag.startLocation)
          }
          guard let nearest, distance(handlePoint(nearest, size: size), drag.startLocation) < 16 else { return }
          dragged = nearest.id
          nearest.frequency.onEditingChanged(true)
          nearest.gain?.onEditingChanged(true)
          if !nearest.isOn { nearest.on.value = 1 }
        }
        guard let index = dragged else { return }
        let band = controls.bands[index]
        let location = CGPoint(x: min(size.width, max(0, drag.location.x)), y: min(size.height, max(0, drag.location.y)))
        band.frequency.value = min(band.frequency.max, max(band.frequency.min, frequency(atX: location.x, width: size.width)))
        if let gain = band.gain {
          gain.value = min(gain.max, max(gain.min, decibels(atY: location.y, height: size.height)))
        }
      }
      .onEnded { _ in
        guard let index = dragged else { return }
        controls.bands[index].frequency.onEditingChanged(false)
        controls.bands[index].gain?.onEditingChanged(false)
        dragged = nil
      }
  }

  private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
  }
}
