//
//  EffectControls.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// The effects' dark, Logic-like look.
enum EffectStyle {
  static let background = Color(white: 0.13)
  static let panel = Color(white: 0.17)
  static let grid = Color(white: 1, opacity: 0.08)
  static let label = Color(white: 0.6)
  static let value = Color(white: 0.92)
}

/// A parameter's value as text, changed by dragging up and down (logarithmic parameters
/// move by ratios, so frequencies sweep evenly by octave). Double-click to type a value;
/// Option-click to reset it.
struct DragValue: View {
  let parameter: ObservableAUParameter
  var tint: Color = EffectStyle.value

  @State private var isTyping = false
  @State private var typed = ""

  var body: some View {
    Group {
      if isTyping {
        TextField("", text: $typed)
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .onSubmit(commit)
          .onExitCommand { isTyping = false }
      } else {
        Text(parameter.text)
          .foregroundStyle(tint)
      }
    }
    .font(.system(size: 11, weight: .medium).monospacedDigit())
    .frame(maxWidth: .infinity, minHeight: 18)
    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35)))
    .contentShape(Rectangle())
    .parameterDrag(parameter)
    .onTapGesture(count: 2) {
      typed = String(format: "%g", parameter.value)
      isTyping = true
    }
  }

  private func commit() {
    var text = typed.lowercased().trimmingCharacters(in: .whitespaces)
    var multiplier: Float = 1
    if text.hasSuffix("k") || text.hasSuffix("khz") {
      multiplier = 1_000
      text = text.replacingOccurrences(of: "khz", with: "").replacingOccurrences(of: "k", with: "")
    }
    for unit in ["lufs", "dbtp", "hz", "db", "ms", "%", ": 1", ":1", "s"] {
      text = text.replacingOccurrences(of: unit, with: "")
    }
    if let number = Float(text.trimmingCharacters(in: .whitespaces)) {
      parameter.value = min(parameter.max, max(parameter.min, number * multiplier))
    }
    isTyping = false
  }
}

/// A labelled row: a small caption over a control.
struct Captioned<Content: View>: View {
  let caption: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 2) {
      Text(caption)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(EffectStyle.label)
      content
    }
  }
}

extension ObservableAUParameter {
  /// The value as the effect shows it ("−12.0 dB", "4.0 : 1", "1.50 kHz").
  var text: String {
    OngakuEffectsAudioUnit.string(for: value, of: unit, valueStrings: valueStrings, unitName: unitName, address: address)
  }

  /// Where the value sits in its range, 0 to 1 (by ratio for logarithmic parameters).
  var position: Double {
    guard max > min else { return 0 }
    if isLogarithmic, min > 0 {
      return Double(log(value / min) / log(max / min))
    }
    return Double((value - min) / (max - min))
  }

  func clamp(_ value: AUValue) -> AUValue {
    Swift.min(max, Swift.max(min, value))
  }
}

extension View {
  /// Changes a parameter by dragging up and down (logarithmic parameters move by ratios,
  /// so frequencies and times sweep evenly), Option-click resets it, as in Logic, and
  /// VoiceOver's adjust actions step it.
  func parameterDrag(_ parameter: ObservableAUParameter) -> some View {
    modifier(ParameterDrag(parameter: parameter))
  }
}

private struct ParameterDrag: ViewModifier {
  let parameter: ObservableAUParameter
  @State private var dragStart: AUValue?

  func body(content: Content) -> some View {
    content
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { drag in
            if dragStart == nil {
              dragStart = parameter.value
              parameter.onEditingChanged(true)
            }
            guard let start = dragStart else { return }
            let distance = Float(-drag.translation.height)
            let value = parameter.isLogarithmic && parameter.min > 0
              ? start * powf(parameter.max / parameter.min, distance / 200)
              : start + distance * (parameter.max - parameter.min) / 200
            parameter.value = parameter.clamp(value)
          }
          .onEnded { _ in
            dragStart = nil
            parameter.onEditingChanged(false)
          }
      )
      .simultaneousGesture(TapGesture().modifiers(.option).onEnded { parameter.resetToDefault() })
      .accessibilityElement()
      .accessibilityLabel(parameter.displayName)
      .accessibilityValue(parameter.text)
      .accessibilityAdjustableAction { direction in
        let step: AUValue = parameter.isLogarithmic ? parameter.value * 0.06 : (parameter.max - parameter.min) / 48
        parameter.value = parameter.clamp(parameter.value + (direction == .increment ? step : -step))
      }
  }
}

/// A rotary control: an arc showing where the value sits in its range, its name and its
/// value. Drag up and down to turn it; Option-click to reset it.
struct Knob: View {
  let parameter: ObservableAUParameter
  var name: String? = nil
  var tint: Color = Color(red: 0.98, green: 0.62, blue: 0.2)
  var diameter: CGFloat = 46
  var valueWidth: CGFloat = 70

  var body: some View {
    VStack(spacing: 3) {
      Text(name ?? parameter.displayName)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(EffectStyle.label)
        .fixedSize()
      ZStack {
        Circle()
          .trim(from: 0, to: 0.75)
          .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Circle()
          .trim(from: 0, to: 0.75 * parameter.position)
          .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Circle()
          .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
          .padding(7)
        Capsule()
          .fill(Color(white: 0.9))
          .frame(width: 2, height: diameter * 0.22)
          .offset(y: -diameter * 0.2)
          .rotationEffect(.degrees(90 + 270 * parameter.position))
      }
      .rotationEffect(.degrees(135), anchor: .center)
      .frame(width: diameter, height: diameter)
      .contentShape(Circle())
      DragValue(parameter: parameter)
        .frame(width: max(valueWidth, diameter + 14))
    }
    .parameterDrag(parameter)
  }
}
