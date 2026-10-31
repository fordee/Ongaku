//
//  SynthPanel.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The look of a hardware synth's front panel, as Logic's and Ableton's synths have it: a
/// dark graphite panel, sections with coloured headers, metal knobs with coloured value
/// rings, lit buttons, and glowing scopes.
enum Synth {
  static let panelTop = Color(red: 0.17, green: 0.175, blue: 0.19)
  static let panelBottom = Color(red: 0.12, green: 0.125, blue: 0.135)
  static let section = Color(red: 0.205, green: 0.21, blue: 0.225)
  static let sectionEdge = Color.white.opacity(0.07)
  static let label = Color(white: 0.62)
  static let value = Color(white: 0.92)
  static let screen = Color(red: 0.06, green: 0.07, blue: 0.08)

  static let oscillator = Color(red: 0.98, green: 0.6, blue: 0.22)
  static let unison = Color(red: 0.95, green: 0.42, blue: 0.62)
  static let filter = Color(red: 0.32, green: 0.66, blue: 1.0)
  static let envelope = Color(red: 0.42, green: 0.85, blue: 0.48)
  static let lfo = Color(red: 0.7, green: 0.5, blue: 1.0)
}

// MARK: - Panel and sections

/// The panel behind everything: graphite, with a faint brushed texture.
struct SynthBackground: View {
  var body: some View {
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
        Gradient(colors: [Synth.panelTop, Synth.panelBottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      for y in stride(from: CGFloat(0), to: size.height, by: 2) {
        let shade = (Int(y) * 7919 % 13 == 0) ? 0.025 : 0.01
        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(shade)))
      }
    }
  }
}

/// A section of the panel, with its name and a coloured rule.
struct SynthSection<Content: View>: View {
  let title: String
  let accent: Color
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(title.uppercased())
          .font(.system(size: 10, weight: .bold))
          .tracking(1.6)
          .foregroundStyle(accent)
          .fixedSize()
        Rectangle().fill(accent.opacity(0.35)).frame(height: 1)
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Synth.section))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Synth.sectionEdge, lineWidth: 1))
    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
  }
}

// MARK: - Controls

/// A metal knob inside a coloured ring that fills with its value, its name above and its
/// value below. Drag up and down to turn it; double-click or Option-click to reset it.
struct SynthKnob: View {
  let parameter: ObservableAUParameter
  let label: String
  var accent: Color
  var size: CGFloat = 44

  var body: some View {
    VStack(spacing: 4) {
      Text(label.uppercased())
        .font(.system(size: 8.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(Synth.label)
        .lineLimit(1)
        .fixedSize()
      ZStack {
        Circle()
          .trim(from: 0, to: 0.75)
          .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
          .rotationEffect(.degrees(135))
        Circle()
          .trim(from: 0, to: 0.75 * parameter.position)
          .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
          .rotationEffect(.degrees(135))
          .shadow(color: accent.opacity(0.6), radius: 3)
        // The knob: a brushed metal cap with a dark skirt.
        Circle()
          .fill(Color(white: 0.09))
          .padding(size * 0.12)
        Circle()
          .fill(AngularGradient(
            colors: [Color(white: 0.55), Color(white: 0.35), Color(white: 0.6), Color(white: 0.32), Color(white: 0.55)],
            center: .center))
          .padding(size * 0.2)
          .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        Capsule()
          .fill(Color.white)
          .frame(width: 2.5, height: size * 0.2)
          .offset(y: -size * 0.18)
          .rotationEffect(.degrees(-135 + 270 * parameter.position))
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
      Text(parameter.text)
        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        .foregroundStyle(Synth.value)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: max(size + 12, 56))
    }
    .parameterDrag(parameter)
    .onTapGesture(count: 2) { parameter.resetToDefault() }
  }
}

/// Lit push buttons in a row, one on: wave and mode selectors.
struct SynthButtons: View {
  let parameter: ObservableAUParameter
  let options: [(name: String, glyph: WaveGlyph.Kind)]
  var accent: Color
  /// What value the first button stands for (1 for parameters that start at 1).
  var firstValue = 0
  /// Wider for buttons with words on them.
  var buttonWidth: CGFloat = 28

  var body: some View {
    HStack(spacing: 3) {
      ForEach(options.indices, id: \.self) { index in
        let isOn = Int(parameter.value.rounded()) == index + firstValue
        Button {
          parameter.value = AUValue(index + firstValue)
        } label: {
          WaveGlyph(kind: options[index].glyph, color: isOn ? accent : Synth.label)
            .frame(width: buttonWidth, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? accent.opacity(0.18) : Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: isOn ? accent.opacity(0.45) : .clear, radius: 3)
        }
        .buttonStyle(.plain)
        .help(options[index].name)
        .accessibilityLabel(options[index].name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
  }
}

/// A small drawing of a waveform (or a word) for a button.
struct WaveGlyph: View {
  enum Kind {
    case saw, pulse, triangle, sine, square, random, text(String)
  }

  let kind: Kind
  let color: Color

  var body: some View {
    if case .text(let text) = kind {
      Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
    } else {
      Canvas { context, size in
        context.stroke(Self.path(kind, in: CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 5)),
          with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
      }
    }
  }

  static func path(_ kind: Kind, in rect: CGRect) -> Path {
    var path = Path()
    let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
    switch kind {
    case .saw:
      path.move(to: CGPoint(x: x, y: y + h))
      path.addLine(to: CGPoint(x: x + w / 2, y: y))
      path.addLine(to: CGPoint(x: x + w / 2, y: y + h))
      path.addLine(to: CGPoint(x: x + w, y: y))
    case .pulse, .square:
      path.move(to: CGPoint(x: x, y: y + h))
      path.addLine(to: CGPoint(x: x, y: y))
      path.addLine(to: CGPoint(x: x + w / 2, y: y))
      path.addLine(to: CGPoint(x: x + w / 2, y: y + h))
      path.addLine(to: CGPoint(x: x + w, y: y + h))
      path.addLine(to: CGPoint(x: x + w, y: y))
    case .triangle:
      path.move(to: CGPoint(x: x, y: y + h))
      path.addLine(to: CGPoint(x: x + w / 2, y: y))
      path.addLine(to: CGPoint(x: x + w, y: y + h))
    case .sine:
      for step in 0...24 {
        let t = CGFloat(step) / 24
        let point = CGPoint(x: x + t * w, y: y + h / 2 - sin(t * 2 * .pi) * h / 2)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
    case .random:
      let levels: [CGFloat] = [0.6, 0.1, 0.9, 0.35, 0.75]
      for (index, level) in levels.enumerated() {
        let x0 = x + CGFloat(index) / CGFloat(levels.count) * w
        let x1 = x + CGFloat(index + 1) / CGFloat(levels.count) * w
        if index == 0 { path.move(to: CGPoint(x: x0, y: y + level * h)) } else { path.addLine(to: CGPoint(x: x0, y: y + level * h)) }
        path.addLine(to: CGPoint(x: x1, y: y + level * h))
      }
    case .text:
      break
    }
    return path
  }
}

/// A dark screen with a faint grid, for scopes.
struct SynthScreen<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .background(
        Canvas { context, size in
          context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Synth.screen))
          for x in stride(from: size.width / 8, to: size.width, by: size.width / 8) {
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.04)))
          }
          context.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)), with: .color(.white.opacity(0.06)))
        })
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
  }
}

/// Strokes a trace with a soft glow, as a scope draws it.
func glow(_ path: Path, _ color: Color, in context: GraphicsContext, width: CGFloat = 1.6) {
  context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: width + 3)
  context.stroke(path, with: .color(color), lineWidth: width)
}

// MARK: - Keyboard

/// A playable keyboard: click (or drag across) the keys to hear the instrument.
struct PlayableKeyboard: View {
  let lowestNote: Int
  let octaves: Int
  var accent: Color = Synth.oscillator
  /// A key to mark with a dot (the Sampler's root note).
  var markedNote: Int?
  let play: (Int, Bool) -> Void

  @State private var held: Int?

  private static let whiteSteps = [0, 2, 4, 5, 7, 9, 11]
  private static let blackSteps: [(step: Int, afterWhite: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]

  var body: some View {
    GeometryReader { proxy in
      let whiteCount = octaves * 7 + 1
      let whiteWidth = proxy.size.width / CGFloat(whiteCount)
      let height = proxy.size.height
      ZStack(alignment: .topLeading) {
        ForEach(0..<whiteCount, id: \.self) { index in
          let note = lowestNote + (index / 7) * 12 + Self.whiteSteps[index % 7]
          UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
            .fill(held == note
              ? AnyShapeStyle(accent.opacity(0.85))
              : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.98)], startPoint: .top, endPoint: .bottom)))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).strokeBorder(.black.opacity(0.55), lineWidth: 1))
            .overlay(alignment: .bottom) {
              if note == markedNote {
                Circle().fill(accent).frame(width: 7, height: 7).padding(.bottom, 14)
              } else if note % 12 == 0 {
                Text("C\(note / 12 - 2)").font(.system(size: 8, weight: .semibold)).foregroundStyle(.black.opacity(0.45))
                  .padding(.bottom, 3)
              }
            }
            .frame(width: whiteWidth - 1, height: height)
            .offset(x: CGFloat(index) * whiteWidth)
        }
        ForEach(0..<(octaves * 5), id: \.self) { index in
          let black = Self.blackSteps[index % 5]
          let octave = index / 5
          let note = lowestNote + octave * 12 + black.step
          let x = (CGFloat(octave * 7 + black.afterWhite) + 1) * whiteWidth - whiteWidth * 0.3
          UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
            .fill(held == note
              ? AnyShapeStyle(accent)
              : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)))
            .overlay(alignment: .bottom) {
              if note == markedNote {
                Circle().fill(accent).frame(width: 6, height: 6).padding(.bottom, 5)
              }
            }
            .frame(width: whiteWidth * 0.6, height: height * 0.6)
            .offset(x: x)
        }
      }
      // Offsets don't move a view's frame, so without this the keyboard would only take
      // clicks over its first key.
      .frame(width: proxy.size.width, height: height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let note = noteAt(value.location, whiteWidth: whiteWidth, height: height)
            guard note != held else { return }
            if let held { play(held, false) }
            held = note
            if let note { play(note, true) }
          }
          .onEnded { _ in
            if let held { play(held, false) }
            held = nil
          })
    }
    .accessibilityElement()
    .accessibilityLabel("Keyboard")
  }

  private func noteAt(_ point: CGPoint, whiteWidth: CGFloat, height: CGFloat) -> Int? {
    guard point.x >= 0, point.y >= 0, point.y <= height else { return nil }
    if point.y < height * 0.6 {
      for index in 0..<(octaves * 5) {
        let black = Self.blackSteps[index % 5]
        let octave = index / 5
        let x = (CGFloat(octave * 7 + black.afterWhite) + 1) * whiteWidth - whiteWidth * 0.3
        if point.x >= x, point.x <= x + whiteWidth * 0.6 { return lowestNote + octave * 12 + black.step }
      }
    }
    let index = Int(point.x / whiteWidth)
    guard index >= 0, index <= octaves * 7 else { return nil }
    return lowestNote + (index / 7) * 12 + Self.whiteSteps[index % 7]
  }
}
