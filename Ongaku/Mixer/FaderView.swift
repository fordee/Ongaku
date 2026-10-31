//
//  FaderView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Maps fader positions to decibels with a console-style taper: most of the travel covers the
/// useful range around 0 dB, and the bottom of the fader is silence.
enum FaderScale {
  static let maximum = ChannelStrip.volumeRange.upperBound

  /// Decibels for a position from 0 (bottom) to 1 (top).
  static func decibels(atPosition position: Double) -> Double {
    guard position > 0.001 else { return ChannelStrip.volumeRange.lowerBound }
    return max(ChannelStrip.volumeRange.lowerBound, 40 * log10(position) + maximum)
  }

  static func position(forDecibels decibels: Double) -> Double {
    guard decibels > ChannelStrip.volumeRange.lowerBound else { return 0 }
    return min(1, pow(10, (decibels - maximum) / 40))
  }

  /// "0.0", "-12.5" or "-∞", as on Logic's channel strips.
  static func label(_ decibels: Double) -> String {
    decibels <= ChannelStrip.volumeRange.lowerBound ? "-∞" : decibels.formatted(.number.precision(.fractionLength(1)))
  }

  /// The levels marked beside the fader.
  static let marks: [Double] = [6, 0, -6, -12, -24, -48]
}

/// A Logic-style vertical fader: a recessed groove with a dB scale and a metal cap.
/// Dragging calls `onChange` continuously (for live audio) and `onCommit` once at the end
/// (for the undoable edit). Option-click resets it to 0 dB.
struct FaderView: View {
  let decibels: Double
  let onChange: (Double) -> Void
  let onCommit: (Double) -> Void

  @State private var dragValue: Double?

  private static let capHeight: CGFloat = 26
  private static let inset = capHeight / 2

  var body: some View {
    let value = dragValue ?? decibels
    GeometryReader { geometry in
      let travel = max(geometry.size.height - Self.capHeight, 1)
      let capY = travel * (1 - FaderScale.position(forDecibels: value))
      ZStack(alignment: .top) {
        // The scale and groove don't move, so they're a separate view that isn't redrawn as
        // the fader moves; only the cap is.
        FaderTrack(travel: travel, inset: Self.inset)
          .equatable()

        FaderCap()
          .offset(y: capY)
      }
      .frame(maxWidth: .infinity)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            let position = 1 - (gesture.location.y - Self.inset) / travel
            let newValue = FaderScale.decibels(atPosition: min(max(position, 0), 1))
            dragValue = newValue
            onChange(newValue)
          }
          .onEnded { _ in
            if let dragValue { onCommit(dragValue) }
            dragValue = nil
          }
      )
      .simultaneousGesture(TapGesture().modifiers(.option).onEnded { onCommit(0) })
    }
    .help("Volume. Option-click to reset to 0 dB")
    .accessibilityElement()
    .accessibilityLabel("Volume")
    .accessibilityValue("\(FaderScale.label(value)) dB")
    .accessibilityIdentifier("fader")
    .accessibilityAdjustableAction { direction in
      onCommit(min(max(value + (direction == .increment ? 1 : -1), ChannelStrip.volumeRange.lowerBound), FaderScale.maximum))
    }
  }
}

/// The fader's dB scale and recessed groove.
private struct FaderTrack: View, Equatable {
  let travel: CGFloat
  let inset: CGFloat

  var body: some View {
    ZStack(alignment: .top) {
      ForEach(FaderScale.marks, id: \.self) { mark in
        let y = inset + travel * (1 - FaderScale.position(forDecibels: mark))
        HStack(spacing: 2) {
          Text(mark > 0 ? "+\(Int(mark))" : "\(Int(mark))")
            .font(Theme.monospaced(7, weight: .regular))
            .foregroundStyle(mark == 0 ? Theme.secondaryText : Theme.tertiaryText)
            .frame(width: 14, alignment: .trailing)
          Rectangle().fill(Theme.tertiaryText.opacity(mark == 0 ? 1 : 0.6)).frame(width: 4, height: 1)
          Spacer(minLength: 0)
        }
        .frame(height: 8)
        .offset(y: y - 4)
      }

      RoundedRectangle(cornerRadius: 2)
        .fill(Color.black.opacity(0.75))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.07)))
        .frame(width: 4)
        .frame(maxHeight: .infinity)
        .padding(.vertical, inset - 2)
    }
  }
}

/// The fader's cap: brushed light grey with a dark line across the middle.
private struct FaderCap: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(LinearGradient(
        colors: [Color(hex: 0xC9C9CE), Color(hex: 0x8E8E94), Color(hex: 0xB4B4BA)],
        startPoint: .top, endPoint: .bottom))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.55)))
      .overlay(Rectangle().fill(Color.black.opacity(0.75)).frame(height: 2))
      .frame(width: 30, height: 26)
      .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
  }
}

/// How lit one meter is: 0 (silent) to `MeterLevel.steps` per side. A separate observable
/// per meter, updated only when the lit amount changes, so silent meters never redraw.
@MainActor
@Observable
final class MeterLevel {
  /// The meter shows -60 to +6 dBFS in this many steps.
  static let steps = 66
  static let floor = -60.0
  static let ceiling = 6.0

  var left = 0
  var right = 0

  static func step(for peak: Float) -> Int {
    guard peak > 0.000_01 else { return 0 }
    let decibels = Double(20 * log10(peak))
    return Int((Double(steps) * (decibels - floor) / (ceiling - floor)).rounded()).clamped(to: 0...steps)
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

/// A stereo meter made of LED segments, green to yellow to red.
struct MeterView: View {
  let level: MeterLevel

  var body: some View {
    let left = level.left
    let right = level.right
    Canvas { context, size in
      let barWidth = (size.width - 1) / 2
      let segmentHeight: CGFloat = 2
      let gap: CGFloat = 1
      let segments = Int(size.height / (segmentHeight + gap))
      // One path per colour, so a redraw is a handful of fills rather than one per segment.
      var low = Path(), mid = Path(), high = Path(), off = Path()
      for (index, lit) in [left, right].enumerated() {
        let litSegments = segments * lit / MeterLevel.steps
        for segment in 0..<segments {
          let rect = CGRect(
            x: CGFloat(index) * (barWidth + 1), y: size.height - CGFloat(segment + 1) * (segmentHeight + gap),
            width: barWidth, height: segmentHeight)
          guard segment < litSegments else {
            off.addRect(rect)
            continue
          }
          let decibels = MeterLevel.floor + (MeterLevel.ceiling - MeterLevel.floor) * Double(segment) / Double(max(segments - 1, 1))
          if decibels > 0 {
            high.addRect(rect)
          } else if decibels > -12 {
            mid.addRect(rect)
          } else {
            low.addRect(rect)
          }
        }
      }
      context.fill(off, with: .color(Theme.meterOff))
      context.fill(low, with: .color(Theme.meterLow))
      context.fill(mid, with: .color(Theme.meterMid))
      context.fill(high, with: .color(Theme.meterHigh))
    }
    .background(Color.black, in: .rect(cornerRadius: 1))
    .accessibilityHidden(true)
  }
}

/// A Logic-style rotary knob, for pan and send levels. Drag up or down to turn it;
/// double-click or Option-click returns it to its default.
struct Knob: View {
  let value: Double
  let range: ClosedRange<Double>
  /// Pan-style knobs light the arc from the centre; others from the minimum.
  var isBipolar = false
  var defaultValue: Double = 0
  var size: CGFloat = 26
  var tint: Color = Theme.accent
  let label: String
  let valueText: (Double) -> String
  let onChange: (Double) -> Void
  let onCommit: (Double) -> Void

  @State private var dragStart: Double?
  @State private var dragValue: Double?

  /// The knob turns through 270°, from bottom-left to bottom-right.
  private static let startAngle = 135.0
  private static let sweep = 270.0

  var body: some View {
    let shown = dragValue ?? value
    let fraction = (shown - range.lowerBound) / (range.upperBound - range.lowerBound)
    let valueAngle = Self.startAngle + Self.sweep * fraction
    let originAngle = isBipolar ? Self.startAngle + Self.sweep / 2 : Self.startAngle

    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let radius = min(canvasSize.width, canvasSize.height) / 2 - 2
      var track = Path()
      track.addArc(center: center, radius: radius, startAngle: .degrees(Self.startAngle),
        endAngle: .degrees(Self.startAngle + Self.sweep), clockwise: false)
      context.stroke(track, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
      var arc = Path()
      arc.addArc(center: center, radius: radius, startAngle: .degrees(min(originAngle, valueAngle)),
        endAngle: .degrees(max(originAngle, valueAngle)), clockwise: false)
      context.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

      let body = CGRect(x: center.x - radius + 4, y: center.y - radius + 4, width: (radius - 4) * 2, height: (radius - 4) * 2)
      context.fill(Path(ellipseIn: body), with: .linearGradient(
        Gradient(colors: [Color(hex: 0x5E5E64), Color(hex: 0x3A3A3F)]),
        startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))
      context.stroke(Path(ellipseIn: body), with: .color(.black.opacity(0.6)), lineWidth: 1)
      let radians = valueAngle * .pi / 180
      var pointer = Path()
      pointer.move(to: CGPoint(x: center.x + cos(radians) * (radius - 10), y: center.y + sin(radians) * (radius - 10)))
      pointer.addLine(to: CGPoint(x: center.x + cos(radians) * (radius - 5), y: center.y + sin(radians) * (radius - 5)))
      context.stroke(pointer, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
    .frame(width: size, height: size)
    .contentShape(.circle)
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { drag in
          let start = dragStart ?? value
          dragStart = start
          let span = range.upperBound - range.lowerBound
          let newValue = min(max(start - Double(drag.translation.height) / 140 * span, range.lowerBound), range.upperBound)
          dragValue = newValue
          onChange(newValue)
        }
        .onEnded { _ in
          if let dragValue { onCommit(dragValue) }
          dragValue = nil
          dragStart = nil
        }
    )
    .onTapGesture(count: 2) { onCommit(defaultValue) }
    .simultaneousGesture(TapGesture().modifiers(.option).onEnded { onCommit(defaultValue) })
    .help("\(label): \(valueText(shown)). Option-click to reset")
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue(valueText(shown))
    .accessibilityAdjustableAction { direction in
      let step = (range.upperBound - range.lowerBound) / 50
      onCommit(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
    }
  }
}
