//
//  RulerView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The bar ruler. The upper strip holds the cycle range: drag in it to set a new cycle, or
/// click to turn the cycle on and off. Clicking the lower part moves the playhead.
struct RulerView: View {
  let model: ProjectWindowModel

  /// The snapped cycle range while dragging out a new cycle.
  @State private var cycleDrag: (start: Tick, end: Tick)?

  private static let cycleStripHeight: CGFloat = 13

  var body: some View {
    let project = model.project
    let cycleStart = cycleDrag?.start ?? project.cycle.start
    let cycleEnd = cycleDrag?.end ?? project.cycle.end
    let isCycleEnabled = cycleDrag != nil || project.cycle.isEnabled

    ZStack(alignment: .topLeading) {
      // The cycle strip along the top, a shade darker than the bar-number area.
      VStack(spacing: 0) {
        Theme.ruler.opacity(0.75).frame(height: Self.cycleStripHeight + 4)
        Theme.ruler
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(Theme.separator).frame(height: 1)
      }

      let cycleWidth = max(model.x(for: cycleEnd) - model.x(for: cycleStart), 2)
      RoundedRectangle(cornerRadius: 3)
        .fill(isCycleEnabled
          ? LinearGradient(colors: [Theme.cycle, Theme.cycle.opacity(0.8)], startPoint: .top, endPoint: .bottom)
          : LinearGradient(colors: [Theme.cycleOff, Theme.cycleOff.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.45)))
        .frame(width: cycleWidth, height: Self.cycleStripHeight)
        .offset(x: model.x(for: cycleStart), y: 2)

      RulerMarkings(model: model)
    }
    .frame(width: model.contentWidth, height: ProjectWindowModel.Layout.rulerHeight, alignment: .topLeading)
    .contentShape(.rect)
    .gesture(rulerGesture)
  }

  private var rulerGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard value.startLocation.y <= Self.cycleStripHeight + 2,
          abs(value.translation.width) > 3
        else { return }
        cycleDrag = snappedRange(from: value.startLocation.x, to: value.location.x)
      }
      .onEnded { value in
        let isInCycleStrip = value.startLocation.y <= Self.cycleStripHeight + 2
        let isClick = abs(value.translation.width) <= 3
        defer { cycleDrag = nil }

        if isInCycleStrip {
          if isClick {
            model.toggleCycle()
          } else {
            let range = snappedRange(from: value.startLocation.x, to: value.location.x)
            if range.end > range.start {
              model.perform(SetCycle(CycleRange(isEnabled: true, start: range.start, end: range.end)))
            }
          }
        } else {
          model.engine.locate(to: model.snap(model.position(forX: value.location.x)))
        }
      }
  }

  private func snappedRange(from startX: CGFloat, to endX: CGFloat) -> (start: Tick, end: Tick) {
    let first = model.snap(model.position(forX: min(startX, endX)))
    let last = model.snap(model.position(forX: max(startX, endX)))
    return (first, last)
  }
}

/// Bar numbers and beat ticks, drawn only across the render range.
private struct RulerMarkings: View {
  let model: ProjectWindowModel

  var body: some View {
    let range = model.scroll.renderRange
    let tempoMap = model.project.tempoMap
    let pointsPerQuarterNote = model.pointsPerQuarterNote
    let firstBar = max(0, tempoMap.bar(containing: model.position(forX: range.lowerBound)).index)
    let lastPosition = model.position(forX: range.upperBound)
    let barWidth = tempoMap.timeSignature(atBarIndex: firstBar).ticksPerBar.quarterNotes * pointsPerQuarterNote
    // Label every bar when there's room, otherwise every 2nd, 4th, 8th… bar.
    let labelEvery = barWidth >= 30 ? 1 : 1 << Int(ceil(log2(30 / max(barWidth, 0.1))))

    Canvas { context, size in
      func x(_ position: Tick) -> CGFloat {
        CGFloat(position.quarterNotes * pointsPerQuarterNote) - range.lowerBound
      }
      var ticks = Path()
      var barIndex = firstBar
      var barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
      while barStart <= lastPosition {
        let barX = x(barStart)
        let isLabelled = barIndex % labelEvery == 0
        ticks.addRect(CGRect(x: barX, y: size.height - (isLabelled ? 14 : 8), width: 1, height: isLabelled ? 14 : 8))
        if isLabelled {
          context.draw(
            Text("\(barIndex + 1)").font(Theme.monospaced(10)).foregroundStyle(Theme.rulerText),
            at: CGPoint(x: barX + 3, y: size.height - 15), anchor: .topLeading)
        }

        let signature = tempoMap.timeSignature(atBarIndex: barIndex)
        if signature.ticksPerBeat.quarterNotes * pointsPerQuarterNote >= 10 {
          for beat in 1..<signature.beatsPerBar {
            let beatX = x(barStart + signature.ticksPerBeat * Int64(beat))
            // The felt beats of 6/8 and 12/8 a little taller.
            let height: CGFloat = signature.isCompound && beat % 3 == 0 ? 6 : 4
            ticks.addRect(CGRect(x: beatX, y: size.height - height, width: 1, height: height))
          }
        }
        barIndex += 1
        barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
      }
      context.fill(ticks, with: .color(Theme.rulerTick))
    }
    .frame(width: range.upperBound - range.lowerBound, height: ProjectWindowModel.Layout.rulerHeight)
    .offset(x: range.lowerBound)
    .allowsHitTesting(false)
  }
}
