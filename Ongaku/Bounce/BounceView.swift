//
//  BounceView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The Bounce dialog (File > Bounce, ⌘B): choose a format, render, then save.
struct BounceView: View {
  let model: ProjectWindowModel
  @Bindable var bounce: BounceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Bounce “\(model.exportFileName)”").font(.headline)

      switch bounce.phase {
      case .options:
        options
      case .rendering(let progress):
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: progress)
          Text(bounce.isWaitingForFlex ? "Finishing processing flexed audio…" : "Rendering \(model.describeBounceRange(bounce.range))…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 120)
      case .finished(let result):
        summary(of: result)
      }

      HStack {
        Spacer()
        buttons
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private var options: some View {
    Form {
      LabeledContent("Range", value: model.describeBounceRange(bounce.range))
      Picker("File Format", selection: $bounce.settings.format) {
        ForEach(BounceSettings.FileFormat.allCases, id: \.self) { Text($0.name).tag($0) }
      }
      if !bounce.settings.format.bitDepths.isEmpty {
        Picker("Bit Depth", selection: bitDepth) {
          ForEach(bounce.settings.format.bitDepths, id: \.self) { Text($0.name).tag($0) }
        }
      } else {
        LabeledContent("Quality", value: "\(BounceSettings.aacBitRate / 1000) kbit/s")
      }
      Picker("Sample Rate", selection: sampleRate) {
        ForEach(bounce.settings.format.sampleRates, id: \.self) { rate in
          Text("\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz").tag(rate)
        }
      }
      Toggle("Normalize", isOn: $bounce.settings.normalize)
        .help("Raise or lower the whole bounce so its loudest peak sits just below full scale")
      Toggle("Include audio tail", isOn: $bounce.settings.includeTail)
        .help("Keep rendering after the end until reverb and delay have died away")
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(height: 290)
  }

  /// The bit depth shown is the one that will be written, so switching to AIFF with
  /// 32-bit float selected shows 24-bit.
  private var bitDepth: Binding<BounceSettings.BitDepth> {
    Binding(
      get: { bounce.settings.effectiveBitDepth ?? .twentyFour },
      set: { bounce.settings.bitDepth = $0 })
  }

  private var sampleRate: Binding<Double> {
    Binding(get: { bounce.settings.effectiveSampleRate }, set: { bounce.settings.sampleRate = $0 })
  }

  private func summary(of result: BounceResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Length", value: Duration.seconds(result.duration).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1))))
      LabeledContent("Peak", value: result.peakDecibels.isFinite ? "\(result.peakDecibels.formatted(.number.precision(.fractionLength(1)))) dBFS" : "Silent")
      if result.isClipped {
        Label("The mix goes over 0 dBFS and will clip. Lower the faders or turn on Normalize, then bounce again.", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else if !result.peakDecibels.isFinite {
        Label("The bounce is silent. Check that tracks aren’t muted.", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
    .frame(minHeight: 120, alignment: .top)
  }

  @ViewBuilder private var buttons: some View {
    switch bounce.phase {
    case .options:
      Button("Cancel", role: .cancel) { model.closeBounce() }
        .keyboardShortcut(.cancelAction)
      Button("Bounce") { model.startBounce() }
        .keyboardShortcut(.defaultAction)
    case .rendering:
      Button("Cancel", role: .cancel) { bounce.cancel() }
        .keyboardShortcut(.cancelAction)
    case .finished:
      Button("Bounce Again") { bounce.phase = .options }
      Button("Discard", role: .cancel) { model.closeBounce() }
        .keyboardShortcut(.cancelAction)
      Button("Save…") { model.saveBounce() }
        .keyboardShortcut(.defaultAction)
    }
  }
}

#Preview {
  let model = ProjectWindowModel(document: OngakuDocument())
  BounceView(model: model, bounce: BounceModel(range: .zero..<Tick.quarterNotes(32)))
}
