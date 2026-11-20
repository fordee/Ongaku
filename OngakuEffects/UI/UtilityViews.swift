//
//  UtilityViews.swift
//  OngakuEffects
//

import SwiftUI

private let orange = Color(red: 0.98, green: 0.62, blue: 0.2)
private let blue = Color(red: 0.35, green: 0.6, blue: 0.98)
private let green = Color(red: 0.45, green: 0.8, blue: 0.4)

// MARK: - Gain

/// Gain: a picture of the stereo image (how wide, where it leans, whether it's flipped or
/// mono), the switches, and the knobs.
struct GainView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?

  var body: some View {
    // Laid out for 640 × 320.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = timeline.date
        let _ = meters?.update()
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            ImagePicture(
              width: parameters.value("mono") >= 0.5 ? 0 : Double(parameters.value("width")) / 100,
              balance: Double(parameters.value("balance")) / 100, swapped: parameters.value("swap") >= 0.5)
            InOutMeters(meters: meters)
          }
          .frame(height: 120)
          HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 6) {
                ParameterToggle(parameter: parameters["invertLeft"], title: "Ø Left",
                  help: "Flips the left side's polarity (its waveform upside down), to fix a mic out of phase with another.", hint: $hint)
                ParameterToggle(parameter: parameters["invertRight"], title: "Ø Right", help: "Flips the right side's polarity.", hint: $hint)
              }
              HStack(spacing: 6) {
                ParameterToggle(parameter: parameters["swap"], title: "Swap L/R", help: "Left and right change places.", hint: $hint)
                ParameterToggle(parameter: parameters["mono"], title: "Mono",
                  help: "Both sides the same: check the mix still works on one speaker.", hint: $hint)
              }
            }
            Spacer(minLength: 0)
            HintKnob(parameter: parameters["gain"], name: "Gain", help: "Turns the sound up or down, before anything after it.", hint: $hint, diameter: 58)
            HintKnob(parameter: parameters["width"], name: "Width",
              help: "Narrower to the left (0 % is mono), wider to the right (200 % doubles the difference between the sides).",
              hint: $hint, tint: blue)
            HintKnob(parameter: parameters["balance"], name: "Balance", help: "Turns one side down, to lean the sound left or right.", hint: $hint, tint: green)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }
}

/// The stereo image: an arc as wide as the image, leaning with the balance.
private struct ImagePicture: View {
  let width: Double
  let balance: Double
  let swapped: Bool

  var body: some View {
    let (width, balance, swapped) = (width, balance, swapped)
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      let center = CGPoint(x: size.width / 2, y: size.height - 18)
      let reach = min(size.width / 2 - 24, size.height - 30)
      // The speakers' arc, faint.
      var arc = Path()
      arc.addArc(center: center, radius: reach, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
      context.stroke(arc, with: .color(EffectStyle.grid), lineWidth: 1)
      for (label, angle) in [(swapped ? "R" : "L", 200.0), (swapped ? "L" : "R", 340.0)] {
        let point = CGPoint(x: center.x + cos(angle * .pi / 180) * (reach + 10), y: center.y + sin(angle * .pi / 180) * (reach + 10))
        context.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(EffectStyle.label), at: point)
      }
      // The image: 100 % reaches the speakers; the balance leans it. Wider than the speakers
      // is drawn just past them, so it stays above the floor.
      let lean = balance * 50
      let spread = min(min(width, 2) * 70, 88 - abs(lean))
      var image = Path()
      image.addArc(center: center, radius: reach * 0.8, startAngle: .degrees(270 + lean - spread), endAngle: .degrees(270 + lean + spread), clockwise: false)
      context.stroke(image, with: .color(orange), style: StrokeStyle(lineWidth: 8, lineCap: .round))
      context.draw(Text(width == 0 ? "Mono" : "\(Int(width * 100)) % wide").font(.system(size: 10, weight: .medium))
        .foregroundStyle(EffectStyle.label), at: CGPoint(x: center.x, y: center.y - 4))
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Stereo image")
    .accessibilityValue(width == 0 ? "Mono" : "\(Int(width * 100)) percent wide")
  }
}

// MARK: - Tuner

/// The Tuner: the note heard, big, a needle for how sharp or flat (green within 3 cents),
/// and its frequency.
struct TunerView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters

  @State private var hint: String?
  @State private var meters: EffectMeters?
  /// The last note heard, held a moment after the sound stops so the reading doesn't flicker.
  @State private var held: (frequency: Double, date: Date)?

  var body: some View {
    // Laid out for 640 × 360.
    EffectPanel(audioUnit: audioUnit, hint: $hint) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let _ = meters?.update()
        let heard = Double(meters?.value(.tunerFrequency) ?? 0)
        let reading = TunerReading(frequency: heard > 0 ? heard : (held.map { timeline.date.timeIntervalSince($0.date) < 0.6 ? $0.frequency : 0 } ?? 0),
          reference: Double(parameters.value("reference")))
        let _ = remember(heard, at: timeline.date)
        VStack(spacing: 10) {
          TunerDial(reading: reading)
            .frame(height: 190)
          HStack(spacing: 14) {
            ParameterToggle(parameter: parameters["mute"], title: "Mute While Tuning",
              help: "Silences what comes out, so you can tune on stage without the audience hearing.", hint: $hint)
            Spacer(minLength: 0)
            HintKnob(parameter: parameters["reference"], name: "Reference",
              help: "The pitch of the A above middle C. 440 Hz is standard; some orchestras tune higher.", hint: $hint, tint: blue)
          }
        }
      }
    }
    .onAppear { if meters == nil { meters = EffectMeters(audioUnit: audioUnit) } }
  }

  private func remember(_ frequency: Double, at date: Date) {
    if frequency > 0 { Task { @MainActor in held = (frequency, date) } }
  }
}

/// A frequency as a note: its name (middle C is C3, as in the Piano Roll) and how many
/// cents sharp or flat.
struct TunerReading {
  let frequency: Double
  let reference: Double

  static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

  var isHeard: Bool { frequency > 0 }

  /// The note number, unrounded.
  private var position: Double { 69 + 12 * log2(frequency / reference) }

  var note: Int { Int(position.rounded()) }
  var cents: Double { (position - Double(note)) * 100 }
  var name: String { Self.names[((note % 12) + 12) % 12] }
  var octave: Int { note / 12 - 2 }
}

private struct TunerDial: View {
  let reading: TunerReading

  var body: some View {
    let reading = reading
    let inTune = reading.isHeard && abs(reading.cents) <= 3
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
      // The needle swings above its pivot; the note is read underneath.
      let center = CGPoint(x: size.width / 2, y: size.height * 0.6)
      let radius = min(size.width / 2 - 20, center.y - 12)
      // −50 to +50 cents across 120°.
      func angle(_ cents: Double) -> Angle { .degrees(270 + cents / 50 * 60) }
      for cents in stride(from: -50.0, through: 50, by: 10) {
        let a = angle(cents).radians
        let inner = radius * (cents == 0 ? 0.82 : 0.9)
        context.stroke(Path {
          $0.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
          $0.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        }, with: .color(cents == 0 ? green : EffectStyle.label.opacity(0.5)), lineWidth: cents == 0 ? 2 : 1)
      }
      var zone = Path()
      zone.addArc(center: center, radius: radius * 0.95, startAngle: angle(-3), endAngle: angle(3), clockwise: false)
      context.stroke(zone, with: .color(green.opacity(0.6)), lineWidth: 6)
      context.draw(Text("♭").font(.system(size: 14, weight: .bold)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: center.x - radius * 0.95, y: center.y - radius * 0.45))
      context.draw(Text("♯").font(.system(size: 14, weight: .bold)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: center.x + radius * 0.95, y: center.y - radius * 0.45))
      if reading.isHeard {
        let a = angle(min(max(reading.cents, -50), 50)).radians
        context.stroke(Path {
          $0.move(to: center)
          $0.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.92, y: center.y + sin(a) * radius * 0.92))
        }, with: .color(inTune ? green : orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
      }
      context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(EffectStyle.label))
      let noteText = reading.isHeard ? "\(reading.name)\(reading.octave)" : "–"
      context.draw(Text(noteText).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(inTune ? green : .white),
        at: CGPoint(x: center.x, y: center.y + 28))
      let detail = reading.isHeard
        ? String(format: "%.1f Hz   %+.0f cents", reading.frequency, reading.cents) : "Play a single note"
      context.draw(Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(EffectStyle.label),
        at: CGPoint(x: center.x, y: center.y + 56))
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityElement()
    .accessibilityLabel("Tuner")
    .accessibilityValue(reading.isHeard ? "\(reading.name)\(reading.octave), \(Int(reading.cents.rounded())) cents" : "No note")
  }
}

#Preview("Gain") {
  PluginPreview(effect: .gain, values: [.ginWidth: 140, .ginBalance: -20, .ginInvertLeft: 1])
}

#Preview("Tuner") {
  PluginPreview(effect: .tuner) { audioUnit in
    audioUnit.meters[Int(OngakuMeter.tunerFrequency.rawValue)] = 442.5
  }
}
