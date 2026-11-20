//
//  BounceView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The Bounce dialog (File > Bounce, ⌘B): choose a format, render, then save. It's also
/// Export All Tracks as Audio Files (⇧⌘E), with a file for each track.
struct BounceView: View {
  let model: ProjectWindowModel
  @Bindable var bounce: BounceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(bounce.target == .mix ? "Bounce “\(model.exportFileName)”" : "Export All Tracks of “\(model.exportFileName)”")
        .font(.headline)

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
      case .finishedTracks(_, let files):
        VStack(alignment: .leading, spacing: 8) {
          LabeledContent("Files", value: files.count == 1 ? "1 track" : "\(files.count) tracks")
          Text(files.map(\.lastPathComponent).joined(separator: "\n"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(6)
        }
        .frame(minHeight: 120, alignment: .top)
      }

      HStack {
        Spacer()
        buttons
      }
    }
    .padding(20)
    .frame(width: 420)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bounce")
    .accessibilityIdentifier("bounce")
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
      if bounce.target == .mix {
        Toggle("Normalize", isOn: $bounce.settings.normalize)
          .help("Raise or lower the whole bounce so its loudest peak sits just below full scale")
      } else {
        Toggle("Include effect plug-ins", isOn: $bounce.trackOptions.includesEffects)
          .help("Render each track through its insert plug-ins; off, only the instrument and MIDI effects")
        Toggle("Include volume and pan", isOn: $bounce.trackOptions.includesVolumeAndPan)
          .help("Render each track at its fader's level and pan, with their automation; off, at 0 dB in the centre")
      }
      Toggle("Include audio tail", isOn: $bounce.settings.includeTail)
        .help("Keep rendering after the end until reverb and delay have died away")
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(height: bounce.target == .mix ? 290 : 330)
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
      Button(bounce.target == .mix ? "Bounce" : "Export") { model.startBounce() }
        .keyboardShortcut(.defaultAction)
    case .rendering:
      Button("Cancel", role: .cancel) { bounce.cancel() }
        .keyboardShortcut(.cancelAction)
    case .finished, .finishedTracks:
      Button(bounce.target == .mix ? "Bounce Again" : "Export Again") { bounce.phase = .options }
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

#Preview("Export All Tracks") {
  let model = ProjectWindowModel(document: OngakuDocument())
  BounceView(model: model, bounce: BounceModel(range: .zero..<Tick.quarterNotes(32), target: .allTracks))
}
