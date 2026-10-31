//
//  MasteringView.swift
//  OngakuEffects
//

import AudioToolbox
import OngakuCore
import SwiftUI

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)
private let red = Color(red: 0.98, green: 0.4, blue: 0.25)

/// Mastering, guided like Logic's Mastering Assistant: Listen (play the song, and it works
/// out the EQ, compression and loudness), see how the song's balance compares with a
/// typical master and how loud it is, then choose a character and a loudness by ear, with
/// Compare to hear the difference. Fine-tune shows every setting.
struct MasteringView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters
  let session: PluginSession

  @State private var hint: String?
  @State private var meters: EffectMeters?
  @State private var truePeak = PeakHold()
  @State private var isListening = false
  @State private var analysis: MasteringAnalysis.Result?
  @State private var listenMessage: String?
  @State private var isFineTuning = false
  /// The steps after a listen that have been done (see `NextSteps`).
  @State private var done: Set<NextStep> = []

  var body: some View {
    // Laid out for 960 × 470.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            ListenCard(
              audioUnit: audioUnit, isListening: isListening, isMeasured: isMeasured,
              measured: parameters.value("measuredLoudness"), message: listenMessage, done: done, date: timeline.date,
              hint: $hint, toggle: toggleListening)
              .frame(width: 250)
            if isFineTuning {
              FineTunePanel(parameters: parameters, hint: $hint)
            } else {
              BalanceCard(parameters: parameters, analysis: analysis, hint: $hint)
              LoudnessGauge(
                output: meters?.value(.outputLoudness) ?? -120, target: parameters.value("loudness"),
                truePeak: truePeak.value(meters?.value(.truePeak) ?? -120, at: timeline.date),
                ceiling: parameters.value("ceiling"), limiting: meters?.value(.limiting) ?? 0,
                compression: meters?.reduction ?? 0, isMeasured: isMeasured, hint: $hint)
                .frame(width: 170)
            }
          }
          .frame(height: 262)
          HStack(spacing: 12) {
            CharacterCards(parameter: parameters["character"], hint: $hint)
            LoudnessSlider(parameter: parameters["loudness"], isMeasured: isMeasured, hint: $hint)
              .frame(width: 250)
            VStack(spacing: 8) {
              CompareButton(parameter: parameters["compare"], hint: $hint)
              FineTuneButton(isOn: $isFineTuning, hint: $hint)
            }
            .frame(width: 150)
          }
          .frame(height: 124)
        }
        // Listening stops by itself when it's full (or a host turned Listen off).
        .onChange(of: timeline.date) {
          if isListening, !audioUnit.isListening { finishListening() }
          // The host analysed the whole song (or undid that): show what it found.
          if !isListening, audioUnit.masteringAnalysis != analysis {
            analysis = audioUnit.masteringAnalysis
            listenMessage = nil
            done = []
          }
          // Heard at about the loudness asked for: the loudest part has been played.
          if isMeasured, !isListening, let output = meters?.value(.outputLoudness),
            abs(output - parameters.value("loudness")) < 1.5
          {
            done.insert(.playLoudest)
          }
        }
      }
    }
    .onAppear {
      if meters == nil { meters = EffectMeters(audioUnit: audioUnit) }
      analysis = audioUnit.masteringAnalysis
      isFineTuning = audioUnit.masteringShowsFineTune
      isListening = audioUnit.isListening
      // While the window is open, a listen's settings come here, to be one undoable change.
      audioUnit.masteringListenFinished = { apply($0) }
    }
    .onDisappear { audioUnit.masteringListenFinished = nil }
    .onChange(of: isFineTuning) { audioUnit.masteringShowsFineTune = isFineTuning }
    .onChange(of: parameters.value("character")) { if isMeasured { done.insert(.tryCharacters) } }
    .onChange(of: parameters.value("compare")) { if isMeasured, parameters.value("compare") >= 0.5 { done.insert(.compare) } }
  }

  private var isMeasured: Bool {
    parameters.value("measuredLoudness") > MasteringParameters.notMeasured + 0.05
  }

  private func toggleListening() {
    if isListening {
      finishListening()
    } else {
      listenMessage = nil
      done = []
      audioUnit.startListening()
      isListening = true
    }
  }

  /// Turns Listen off: the Audio Unit analyses what it heard and hands the result to `apply`.
  private func finishListening() {
    isListening = false
    audioUnit.stopListening()
  }

  private func apply(_ result: MasteringAnalysis.Result?) {
    isListening = false
    guard let result else {
      listenMessage = "Not enough music heard. Play at least \(Int(MasteringAnalysis.minimumSeconds)) seconds, then click Done."
      return
    }
    session.set(OngakuEffectsAudioUnit.masteringSettings(for: result))
    analysis = result
    listenMessage = nil
  }
}

// MARK: - Cards

/// A rounded panel with a small title, the window's building block.
private struct Card<Content: View>: View {
  let title: String
  var trailing: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(EffectStyle.label)
        Spacer()
        if let trailing {
          Text(trailing).font(.system(size: 9)).foregroundStyle(EffectStyle.label)
        }
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(EffectStyle.panel))
  }
}

// MARK: - Listen

/// Listen, as a ring that fills while it listens (a minute fills it), with what it found
/// underneath once it has listened.
private struct ListenCard: View {
  let audioUnit: OngakuEffectsAudioUnit
  let isListening: Bool
  let isMeasured: Bool
  let measured: Float
  let message: String?
  let done: Set<NextStep>
  let date: Date
  @Binding var hint: String?
  let toggle: () -> Void

  private let help = "Click, then play your song: all of it, or at least its loudest part. Click Done, and it sets the EQ, compression and loudness for the song."

  var body: some View {
    Card(title: "Listen") {
      VStack(spacing: showsSteps ? 8 : 10) {
        Button(action: toggle) {
          ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
              .trim(from: 0, to: progress)
              .stroke(isListening ? green : isMeasured ? green.opacity(0.75) : Color.clear,
                style: StrokeStyle(lineWidth: 8, lineCap: .round))
              .rotationEffect(.degrees(-90))
            if isListening {
              // A soft pulse, so it's plain it's listening even before the ring moves.
              Circle()
                .fill(green.opacity(0.1 + 0.08 * sin(date.timeIntervalSinceReferenceDate * 4)))
                .padding(14)
            }
            VStack(spacing: 2) {
              Image(systemName: isListening ? "stop.fill" : isMeasured ? "checkmark" : "ear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isListening || isMeasured ? green : EffectStyle.value)
              Text(isListening ? "Done" : isMeasured ? "Listen Again" : "Listen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EffectStyle.value)
              Text(isListening ? heard : isMeasured ? String(format: "%.1f LUFS", measured) : " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(EffectStyle.label)
            }
          }
          .frame(width: showsSteps ? 92 : 118, height: showsSteps ? 92 : 118)
          .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
        .accessibilityLabel(isListening ? "Done Listening" : isMeasured ? "Listen Again" : "Listen")
        .accessibilityValue(isListening ? heard : isMeasured ? String(format: "Measured %.1f LUFS", measured) : "Not measured")

        if showsSteps {
          NextSteps(done: done, hint: $hint)
        } else {
          Text(caption)
            .font(.system(size: 10.5))
            .foregroundStyle(message == nil ? EffectStyle.label : orange)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  /// After a listen, what to do next takes the caption's place.
  private var showsSteps: Bool { isMeasured && !isListening && message == nil }

  private var seconds: Int { audioUnit.listenedBlockCount / 10 }

  /// How long it has listened, as m:ss (silence is left out later, by the analysis).
  private var heard: String {
    _ = date
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
  }

  private var progress: CGFloat {
    if isListening { return CGFloat(min(Double(seconds) / 60, 1)) }
    return isMeasured ? 1 : 0
  }

  private var caption: String {
    if let message { return message }
    if isListening { return "Listening. Play the song through, or its loudest part, then click Done." }
    return "Click Listen and play your song. Mastering sets itself up from what it hears."
  }
}

/// What's left to do after a listen, each ticked off as it's done.
enum NextStep: CaseIterable {
  case playLoudest, tryCharacters, compare, bounce

  var title: String {
    switch self {
    case .playLoudest: "Play the loudest part"
    case .tryCharacters: "Try each character"
    case .compare: "Compare with the original"
    case .bounce: "Set the loudness, then bounce"
    }
  }

  var help: String {
    switch self {
    case .playLoudest: "Play the song's loudest part. The Loudness meter settles near your target once it's set for the song."
    case .tryCharacters: "Click the characters below while the song plays, and keep the one you like: Clean is the neutral start."
    case .compare: "Click Compare to hear the original at the same loudness, then again for the master. If the master isn't better, try another character, or turn EQ Amount or Dynamics down in Fine-Tune."
    case .bounce: "−14 LUFS suits streaming; go louder only to match loud records. Mastering stays on Stereo Out, so a bounce is the master."
    }
  }
}

private struct NextSteps: View {
  let done: Set<NextStep>
  @Binding var hint: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("NEXT").font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(EffectStyle.label)
      ForEach(Array(NextStep.allCases.enumerated()), id: \.element) { index, step in
        let isDone = done.contains(step)
        HStack(spacing: 7) {
          ZStack {
            Circle()
              .fill(isDone ? green : Color.clear)
              .strokeBorder(isDone ? Color.clear : Color.white.opacity(0.3), lineWidth: 1)
            if isDone {
              Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
            } else {
              Text("\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(EffectStyle.label)
            }
          }
          .frame(width: 16, height: 16)
          Text(step.title)
            .font(.system(size: 11, weight: isDone ? .regular : .medium))
            .foregroundStyle(isDone ? EffectStyle.label : EffectStyle.value)
            .strikethrough(isDone, color: EffectStyle.label)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(step.help)
        .onHover { hint = $0 ? step.help : (hint == step.help ? nil : hint) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1): \(step.title)")
        .accessibilityValue(isDone ? "Done" : "")
        .accessibilityHint(step.help)
      }
    }
    .padding(.horizontal, 6)
  }
}

// MARK: - Tonal balance

/// The song's balance against a typical master's (the flat line), as Listen measured it, and
/// the mastering EQ that evens it out.
private struct BalanceCard: View {
  let parameters: EffectParameters
  let analysis: MasteringAnalysis.Result?
  @Binding var hint: String?

  private static let range: ClosedRange<Double> = 25...18_000
  private static let decibels = 8.0
  private let help = "Blue: your song's balance, from low to high, against a typical finished master (the flat line). Orange: the EQ Mastering uses to even it out."

  var body: some View {
    Card(title: "Tonal Balance") {
      ZStack {
        Canvas { context, size in
          draw(in: &context, size: size)
        }
        if analysis == nil {
          Text("Listen to see how your song's balance compares with a typical master.")
            .font(.system(size: 11))
            .foregroundStyle(EffectStyle.label)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .offset(y: -30)
        }
      }
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
      .accessibilityElement()
      .accessibilityLabel("Tonal balance")
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 12) {
          if analysis != nil { legend("Your song", blue) }
          legend("Mastering EQ", orange)
          legend("Typical master", .white.opacity(0.35), dashed: true)
        }
        .offset(y: -22)
        .accessibilityHidden(true)
      }
      .accessibilityValue(accessibilitySummary)
    }
  }

  private func legend(_ title: String, _ color: Color, dashed: Bool = false) -> some View {
    HStack(spacing: 4) {
      Capsule().fill(color).frame(width: dashed ? 5 : 12, height: 2)
      if dashed { Capsule().fill(color).frame(width: 5, height: 2) }
      Text(title).font(.system(size: 9)).foregroundStyle(EffectStyle.label)
    }
  }

  private func x(_ frequency: Double, _ width: CGFloat) -> CGFloat {
    CGFloat(log(frequency / Self.range.lowerBound) / log(Self.range.upperBound / Self.range.lowerBound)) * width
  }

  private func y(_ decibels: Double, _ height: CGFloat) -> CGFloat {
    height / 2 - CGFloat(min(max(decibels, -Self.decibels), Self.decibels) / Self.decibels) * (height / 2 - 6)
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let width = size.width, height = size.height - 14
    // Octave lines and labels.
    for (frequency, label) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
      var line = Path()
      line.move(to: CGPoint(x: x(frequency, width), y: 0))
      line.addLine(to: CGPoint(x: x(frequency, width), y: height))
      context.stroke(line, with: .color(EffectStyle.grid))
      context.draw(
        Text(label).font(.system(size: 8.5)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: x(frequency, width), y: height + 7))
    }
    // The typical master: flat.
    var flat = Path()
    flat.move(to: CGPoint(x: 0, y: y(0, height)))
    flat.addLine(to: CGPoint(x: width, y: y(0, height)))
    context.stroke(flat, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

    // The song's balance, through the measured bands.
    if let analysis {
      let points = zip(MasteringAnalysis.bandCenters, analysis.balance).compactMap { frequency, value in
        value.map { CGPoint(x: x(frequency, width), y: y($0, height)) }
      }
      if let first = points.first {
        var area = Path(), line = Path()
        area.move(to: CGPoint(x: first.x, y: y(0, height)))
        line.move(to: first)
        area.addLine(to: first)
        for point in points.dropFirst() {
          line.addLine(to: point)
          area.addLine(to: point)
        }
        area.addLine(to: CGPoint(x: points.last!.x, y: y(0, height)))
        context.fill(area, with: .color(blue.opacity(0.14)))
        context.stroke(line, with: .color(blue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        for point in points {
          context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(blue))
        }
      }
    }

    // The mastering EQ, as the plug-in plays it.
    let response = eqResponse(count: 120)
    var curve = Path()
    for (index, (frequency, decibels)) in response.enumerated() {
      let point = CGPoint(x: x(frequency, width), y: y(decibels, height))
      if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
    }
    context.stroke(curve, with: .color(orange), style: StrokeStyle(lineWidth: 2, lineCap: .round))
  }

  /// The EQ curve at `count` frequencies across the range, from the plug-in's own filters.
  private func eqResponse(count: Int) -> [(Double, Double)] {
    let frequencies = (0..<count).map { index in
      Float(Self.range.lowerBound * pow(Self.range.upperBound / Self.range.lowerBound, Double(index) / Double(count - 1)))
    }
    let gains = ["eqLowShelf", "eqLowMid", "eqPresence", "eqAir", "eqHighShelf"].map { parameters.value($0) }
    var decibels = [Float](repeating: 0, count: count)
    gains.withUnsafeBufferPointer { gains in
      frequencies.withUnsafeBufferPointer { frequencies in
        decibels.withUnsafeMutableBufferPointer { decibels in
          OngakuMasteringEQResponse(
            Int32(parameters.value("character").rounded()), parameters.value("eqAmount"), gains.baseAddress, 48_000,
            frequencies.baseAddress, decibels.baseAddress, Int32(count))
        }
      }
    }
    return zip(frequencies, decibels).map { (Double($0), Double($1)) }
  }

  private var accessibilitySummary: String {
    guard let analysis else { return "Not measured yet" }
    let names = ["Low", "Low-Mid", "Presence", "Air", "High"]
    let changes = zip(names, analysis.eq).filter { abs($0.1) >= 0.1 }.map { String(format: "%@ %+.1f dB", $0.0, $0.1) }
    return changes.isEmpty ? "Balanced like a typical master" : "EQ: " + changes.joined(separator: ", ")
  }
}

// MARK: - Loudness

/// How loud the master is (the last 3 seconds) against the loudness asked for, with the true
/// peak and how hard the limiter and compressor are working.
private struct LoudnessGauge: View {
  let output: Float
  let target: Float
  let truePeak: Float
  let ceiling: Float
  let limiting: Float
  let compression: Float
  let isMeasured: Bool
  @Binding var hint: String?

  private static let range: ClosedRange<Float> = -30...(-4)
  private let help = "How loud the master is over the last 3 seconds (orange), against the loudness you've chosen (the white line). It reaches it once the song has been listened to."

  var body: some View {
    Card(title: "Loudness") {
      HStack(alignment: .top, spacing: 10) {
        GeometryReader { geometry in
          let height = geometry.size.height
          ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5))
            RoundedRectangle(cornerRadius: 4)
              .fill(LinearGradient(colors: [orange.opacity(0.6), orange], startPoint: .bottom, endPoint: .top))
              .frame(height: height * fraction(output))
            Rectangle()
              .fill(Color.white)
              .frame(height: 2)
              .offset(y: -height * fraction(target) + 1)
          }
        }
        .frame(width: 22)
        VStack(alignment: .leading, spacing: 6) {
          readout("Now", output > -100 ? String(format: "%.1f", output) : "—", "LUFS", isLarge: true, color: orange)
          readout("Target", String(format: "%.0f", target), "LUFS", color: EffectStyle.value)
          readout(
            "True Peak", truePeak > -100 ? String(format: "%.1f", truePeak) : "—", "dBTP",
            color: truePeak > ceiling + 0.05 ? red : EffectStyle.value)
          VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "Limiter %.1f dB", min(0, limiting)))
            Text(String(format: "Compressor %.1f dB", min(0, compression)))
          }
          .font(.system(size: 9).monospacedDigit())
          .foregroundStyle(EffectStyle.label)
          if !isMeasured {
            Text("Listen first: until then it isn't turned up.")
              .font(.system(size: 9))
              .foregroundStyle(orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
      .accessibilityElement(children: .combine)
    }
  }

  private func fraction(_ value: Float) -> CGFloat {
    CGFloat((min(max(value, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound)
      / (Self.range.upperBound - Self.range.lowerBound))
  }

  private func readout(_ title: String, _ value: String, _ unit: String, isLarge: Bool = false, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.5).foregroundStyle(EffectStyle.label)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text(value).font(.system(size: isLarge ? 24 : 15, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        Text(unit).font(.system(size: 9)).foregroundStyle(EffectStyle.label)
      }
    }
  }
}

// MARK: - Character

/// The four characters as cards: what each sounds like, the chosen one lit.
private struct CharacterCards: View {
  let parameter: ObservableAUParameter?
  @Binding var hint: String?

  private static let looks: [(symbol: String, description: String)] = [
    ("circle.lefthalf.filled", "Balanced and natural"),
    ("flame", "Warm, with a rounded top"),
    ("bolt", "Drums and hits come through"),
    ("drop", "Hardly coloured: just louder"),
  ]
  private let help = "Clean: as set for the song. Valve: a little tube warmth, softer top. Punch: lets hits through, fuller lows. Transparent: half the EQ and compression, no widening."

  var body: some View {
    if let parameter {
      let chosen = Int(parameter.value.rounded())
      HStack(spacing: 8) {
        ForEach(MasteringParameters.characters.indices, id: \.self) { index in
          let isChosen = index == chosen
          Button {
            parameter.value = AUValue(index)
          } label: {
            VStack(spacing: 6) {
              Image(systemName: Self.looks[index].symbol)
                .font(.system(size: 20, weight: .semibold))
              Text(MasteringParameters.characters[index])
                .font(.system(size: 13, weight: .semibold))
              Text(Self.looks[index].description)
                .font(.system(size: 9.5))
                .opacity(0.75)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            }
            .foregroundStyle(isChosen ? Color.black : EffectStyle.value)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(isChosen ? orange : EffectStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(isChosen ? 0 : 0.06)))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(MasteringParameters.characters[index])
          .accessibilityHint(Self.looks[index].description)
          .accessibilityAddTraits(isChosen ? .isSelected : [])
        }
      }
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Character")
    }
  }
}

/// Loudness as a slider from gentle to loud, with the streaming level marked.
private struct LoudnessSlider: View {
  let parameter: ObservableAUParameter?
  let isMeasured: Bool
  @Binding var hint: String?

  private let help = "How loud the master ends up. Streaming services play songs at about −14 LUFS, so louder than that is turned down there anyway."

  var body: some View {
    Card(title: "Loudness", trailing: word == "Streaming" ? nil : word) {
      if let parameter {
        VStack(spacing: 6) {
          Text(String(format: "%.1f LUFS", parameter.value))
            .font(.system(size: 22, weight: .semibold).monospacedDigit())
            .foregroundStyle(isMeasured ? orange : EffectStyle.label)
          GeometryReader { geometry in
            let width = geometry.size.width
            let position = CGFloat((parameter.value - parameter.min) / (parameter.max - parameter.min))
            ZStack(alignment: .leading) {
              Capsule().fill(Color.black.opacity(0.5)).frame(height: 6)
              Capsule().fill(orange).frame(width: max(6, width * position), height: 6)
              // Streaming's level.
              Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 14)
                .offset(x: width * CGFloat((-14 - parameter.min) / (parameter.max - parameter.min)))
              Circle().fill(Color.white).frame(width: 16, height: 16).shadow(radius: 2)
                .offset(x: width * position - 8)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0)
                .onChanged { drag in
                  if parameter.min == parameter.max { return }
                  parameter.onEditingChanged(true)
                  let fraction = Float(min(max(drag.location.x / width, 0), 1))
                  parameter.value = ((parameter.min + fraction * (parameter.max - parameter.min)) * 2).rounded() / 2
                }
                .onEnded { _ in parameter.onEditingChanged(false) }
            )
          }
          .frame(height: 18)
          HStack {
            Text("Gentle")
            Spacer()
            Text("Streaming")
            Spacer()
            Text("Loud")
          }
          .font(.system(size: 9))
          .foregroundStyle(EffectStyle.label)
        }
        .help(help)
        .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
        .accessibilityElement()
        .accessibilityLabel("Loudness")
        .accessibilityValue(String(format: "%.1f LUFS, %@", parameter.value, word ?? ""))
        .accessibilityAdjustableAction { direction in
          let step: AUValue = direction == .increment ? 0.5 : -0.5
          parameter.value = min(max(parameter.value + step, parameter.min), parameter.max)
        }
      }
    }
  }

  private var word: String? {
    guard let value = parameter?.value else { return nil }
    switch value {
    case ..<(-14.5): return "Gentle"
    case ..<(-12.5): return "Streaming"
    case ..<(-9.5): return "Loud"
    default: return "Very loud"
    }
  }
}

// MARK: - Fine-tune

/// Every setting: the controls, then those Listen chose for the song.
private struct FineTunePanel: View {
  let parameters: EffectParameters
  @Binding var hint: String?

  var body: some View {
    Card(title: "Fine-Tune", trailing: "Listen sets the second row for the song") {
      VStack(spacing: 10) {
        HStack(spacing: 0) {
          knob("eqAmount", "EQ Amount", "How much of the song's EQ is applied.", tint: green)
          knob("dynamics", "Dynamics", "How firmly the compressor works: 50 % as set for the song, less is gentler, more is firmer.", tint: blue)
          knob("width", "Width", "Widens the stereo image above about 300 Hz. 0 % leaves it alone.", tint: blue)
          knob("lowEndMono", "Low-End Mono", "Makes the lows mono below this frequency, for a solid centre and vinyl-safe bass. Turn it all the way down for Off.", tint: blue)
          knob("ceiling", "Ceiling", "The highest the output can go, between samples too. −1 dBTP leaves room for MP3 and AAC encoding.", tint: green)
        }
        Divider().overlay(EffectStyle.grid)
        HStack(spacing: 0) {
          knob("eqLowShelf", "Low", "The low shelf, at 100 Hz.", tint: green)
          knob("eqLowMid", "Low-Mid", "A bell at 250 Hz: boom and mud.", tint: green)
          knob("eqPresence", "Presence", "A bell at 3 kHz: clarity, or harshness.", tint: green)
          knob("eqAir", "Air", "A bell at 7 kHz: sparkle, or sibilance.", tint: green)
          knob("eqHighShelf", "High", "The high shelf, at 10 kHz.", tint: green)
          knob("compThreshold", "Threshold", "Where the compressor starts working.", tint: blue)
          knob("compRatio", "Ratio", "How firmly it works above the threshold (scaled by Dynamics).", tint: blue)
          knob("compAttack", "Attack", "How quickly it acts. Punch makes this slower.", tint: blue)
          knob("compRelease", "Release", "How quickly it lets go.", tint: blue)
        }
      }
    }
  }

  private func knob(_ identifier: String, _ name: String, _ help: String, tint: Color) -> some View {
    HintKnob(parameter: parameters[identifier], name: name, help: help, hint: $hint, tint: tint, diameter: 36)
  }
}

private struct FineTuneButton: View {
  @Binding var isOn: Bool
  @Binding var hint: String?

  private let help = "Shows every setting, to adjust what Listen chose by hand."

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Label(isOn ? "Overview" : "Fine-Tune", systemImage: isOn ? "chart.xyaxis.line" : "slider.horizontal.3")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(EffectStyle.value)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
  }
}

/// Compare: a large lit button that plays the input instead, as late and as loud as the
/// master, to hear what the processing does.
private struct CompareButton: View {
  let parameter: ObservableAUParameter?
  @Binding var hint: String?

  private let help = "Plays the song as it came in, at the same loudness and timing, so you hear only what the mastering changes."

  var body: some View {
    if let parameter {
      let isOn = parameter.boolValue
      Button {
        parameter.boolValue.toggle()
      } label: {
        VStack(spacing: 2) {
          Text("COMPARE").font(.system(size: 12, weight: .bold)).tracking(0.8)
          Text(isOn ? "Hearing the original" : "Hearing the master").font(.system(size: 9))
        }
        .foregroundStyle(isOn ? .black : EffectStyle.value)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? orange : Color.white.opacity(0.1)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(help)
      .onHover { hint = $0 ? help : (hint == help ? nil : hint) }
      .accessibilityLabel("Compare")
      .accessibilityValue(isOn ? "Hearing the original" : "Hearing the master")
    }
  }
}

/// A level held at its highest for three seconds, so a short over is seen.
@MainActor
private final class PeakHold {
  private var held: Float = -120
  private var time = Date.distantPast

  func value(_ latest: Float, at date: Date) -> Float {
    if latest >= held || date.timeIntervalSince(time) > 3 {
      held = latest
      time = date
    }
    return held
  }
}

// MARK: - Previews (make OngakuEffectsPreviews the active scheme)

/// A listen's findings and a master playing, for the previews.
@MainActor
private func playing(_ audioUnit: OngakuEffectsAudioUnit, fineTune: Bool = false) {
  audioUnit.masteringAnalysis = MasteringAnalysis.Result(
    loudness: -19.6, truePeak: -0.4, peakToLoudness: 19.2, balance: [3.5, 4.2, 2.8, 1.6, 0.3, 0, -0.6, 1.8, -0.8, -3.2],
    sideToMid: -15, eq: [-1.5, -0.3, -0.4, 0.4, 1.1], threshold: -22.5, ratio: 2, width: 20, seconds: 182)
  let readings: [(OngakuMeter, Float)] = [
    (.inputPeak, -6), (.outputPeak, -1.2), (.gainReduction, -1.8), (.inputLoudness, -19.4), (.outputLoudness, -14.3),
    (.limiting, -2.1), (.truePeak, -1.1), (.makeUp, 6.2),
  ]
  for (meter, value) in readings {
    audioUnit.meters[Int(meter.rawValue)] = value
  }
  audioUnit.masteringShowsFineTune = fineTune
}

private let listenedSettings: [OngakuEffectsParameterAddress: AUValue] = [
  .mstMeasuredLoudness: -19.6, .mstLowShelf: -1.5, .mstLowMid: -0.3, .mstPresence: -0.4, .mstAir: 0.4,
  .mstHighShelf: 1.1, .mstThreshold: -22.5, .mstRatio: 2, .mstWidth: 20,
]

#Preview("Before listening") {
  PluginPreview(effect: .mastering) { audioUnit in
    // Silence, as a window shows before anything plays.
    for meter: OngakuMeter in [.inputPeak, .outputPeak, .inputLoudness, .outputLoudness, .truePeak] {
      audioUnit.meters[Int(meter.rawValue)] = -120
    }
  }
}

#Preview("Listened, playing") {
  PluginPreview(effect: .mastering, values: listenedSettings) { playing($0) }
}

#Preview("Fine-tune") {
  PluginPreview(effect: .mastering, values: listenedSettings.merging([.mstCharacter: 1]) { $1 }) { playing($0, fineTune: true) }
}
