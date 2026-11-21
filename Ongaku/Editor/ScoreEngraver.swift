//
//  ScoreEngraver.swift
//  Ongaku
//

import CoreGraphics
import OngakuCore

/// Where everything in a `ScoreLayout` goes on the page: bars spaced by how long their
/// notes last, wrapped into systems that fit the width (and stretched to fill it), each
/// system starting with its clefs, key and time. The score view draws from this, hit-tests
/// with it, and prints it.
struct EngravedScore {
  /// The distance between two staff lines.
  let space: CGFloat
  let layout: ScoreLayout
  var systems: [System] = []
  var size: CGSize = .zero

  struct System {
    var top: CGFloat
    /// Each staff's top line.
    var staffTops: [CGFloat]
    var left: CGFloat
    var right: CGFloat
    var measures: [Measure]
    var bottom: CGFloat
  }

  struct Measure {
    var measure: ScoreMeasure
    var left: CGFloat
    var right: CGFloat
    /// Where the bar's clef, key and time are drawn (from `left`).
    var showsClef: Bool
    var showsKey: Bool
    var showsTime: Bool
    var keyX: CGFloat
    var timeX: CGFloat
    /// Where each moment that something starts is drawn, by its position.
    var onsets: [(tick: Tick, x: CGFloat)]
    var contentLeft: CGFloat
    var space: CGFloat

    func x(at tick: Tick) -> CGFloat {
      guard let first = onsets.first else { return contentLeft }
      if tick <= first.tick { return first.x }
      for (index, onset) in onsets.enumerated() where onset.tick >= tick {
        let previous = onsets[max(0, index - 1)]
        guard onset.tick > previous.tick else { return onset.x }
        let fraction = CGFloat((tick - previous.tick).rawValue) / CGFloat((onset.tick - previous.tick).rawValue)
        return previous.x + (onset.x - previous.x) * fraction
      }
      let last = onsets[onsets.count - 1]
      let fraction = CGFloat((tick - last.tick).rawValue) / CGFloat(max(1, (measure.end - last.tick).rawValue))
      return last.x + (right - space - last.x) * min(1, fraction)
    }
  }

  /// Room above the top staff (chord symbols, high notes) and below the bottom one.
  var headroom: CGFloat { space * 6 }
  var footroom: CGFloat { space * 5 }
  var staffGap: CGFloat { space * 10 }
  var staffHeight: CGFloat { space * 4 }
  let margin: CGFloat

  init(layout: ScoreLayout, width: CGFloat, space: CGFloat = 8, margin: CGFloat = 16, top: CGFloat = 0) {
    self.layout = layout
    self.space = space
    self.margin = margin
    let staffCount = max(1, layout.staves.count)
    let usable = max(space * 30, width - margin * 2)

    // Each bar's natural width, without its header.
    let natural = layout.measures.map { naturalWidth(of: $0) }
    func header(_ measure: ScoreMeasure, startsSystem: Bool) -> (width: CGFloat, clef: Bool, key: Bool, time: Bool) {
      let keyCount = abs(measure.key.sharpsOrFlats)
      let showsKey = (startsSystem || measure.showsKey) && keyCount > 0
      let clefWidth = startsSystem ? space * 3.6 : 0
      let keyWidth = showsKey ? CGFloat(keyCount) * space * 1.05 + space * 0.6 : 0
      let timeWidth = measure.showsSignature ? space * 2.8 : 0
      return (clefWidth + keyWidth + timeWidth + space * 0.6, startsSystem, showsKey, measure.showsSignature)
    }

    var y = top + headroom
    var index = 0
    while index < layout.measures.count {
      // Fill a system.
      var members: [Int] = []
      var used: CGFloat = 0
      while index < layout.measures.count {
        let width = header(layout.measures[index], startsSystem: members.isEmpty).width + natural[index]
        if !members.isEmpty, used + width > usable { break }
        members.append(index)
        used += width
        index += 1
      }
      // Stretch the bars (not their headers) to fill the line, unless it's a short last line.
      let isLast = index >= layout.measures.count
      let contentTotal = members.map { natural[$0] }.reduce(0, +)
      let headers = used - contentTotal
      let stretch = isLast && used < usable * 0.7 ? 1 : max(1, (usable - headers) / max(1, contentTotal))
      var x = margin
      var measures: [Measure] = []
      for (order, member) in members.enumerated() {
        let measure = layout.measures[member]
        let head = header(measure, startsSystem: order == 0)
        let contentWidth = natural[member] * stretch
        let left = x
        let keyX = left + (head.clef ? space * 3.6 : 0)
        let timeX = keyX + (head.key ? CGFloat(abs(measure.key.sharpsOrFlats)) * space * 1.05 + space * 0.6 : 0)
        let contentLeft = left + head.width
        let onsets = onsetPositions(of: measure, from: contentLeft, width: contentWidth)
        measures.append(Measure(
          measure: measure, left: left, right: contentLeft + contentWidth, showsClef: head.clef, showsKey: head.key,
          showsTime: head.time, keyX: keyX, timeX: timeX, onsets: onsets, contentLeft: contentLeft, space: space))
        x = contentLeft + contentWidth
      }
      let staffTops = (0..<staffCount).map { y + CGFloat($0) * (staffHeight + staffGap) }
      let bottom = (staffTops.last ?? y) + staffHeight + footroom
      systems.append(System(top: y - headroom, staffTops: staffTops, left: margin, right: x, measures: measures, bottom: bottom))
      y = bottom + headroom
    }
    if systems.isEmpty {
      systems = [System(top: top, staffTops: [top + headroom], left: margin, right: margin + usable, measures: [], bottom: top + headroom + staffHeight + footroom)]
    }
    size = CGSize(width: width, height: (systems.last?.bottom ?? 0) + space * 2)

  }

  // MARK: - Spacing

  /// A bar's width without its header: room for each moment by how long it lasts.
  private func naturalWidth(of measure: ScoreMeasure) -> CGFloat {
    let onsets = onsetTicks(of: measure)
    if onsets.count <= 1, measure.events.allSatisfy({ $0.allSatisfy(\.isRest) }) { return space * 9 }
    var width = space * 1.6
    for (index, tick) in onsets.enumerated() {
      let next = index + 1 < onsets.count ? onsets[index + 1] : measure.end
      width += spacing(for: next - tick, at: tick, in: measure)
    }
    return width + space * 0.8
  }

  private func onsetPositions(of measure: ScoreMeasure, from left: CGFloat, width: CGFloat) -> [(tick: Tick, x: CGFloat)] {
    let ticks = onsetTicks(of: measure)
    let naturalTotal = naturalWidth(of: measure)
    let scale = width / naturalTotal
    if ticks.count <= 1, measure.events.allSatisfy({ $0.allSatisfy(\.isRest) }) {
      return [(measure.start, left + width / 2)]
    }
    var x = left + space * 1.6 * scale
    return ticks.enumerated().map { index, tick in
      let next = index + 1 < ticks.count ? ticks[index + 1] : measure.end
      // Leave room for an accidental before the note.
      let accidentalRoom = hasAccidental(at: tick, in: measure) ? space * 1.2 * scale : 0
      defer { x += spacing(for: next - tick, at: tick, in: measure) * scale }
      return (tick, x + accidentalRoom)
    }
  }

  private func onsetTicks(of measure: ScoreMeasure) -> [Tick] {
    Array(Set(measure.events.flatMap { $0.map(\.start) })).sorted()
  }

  private func hasAccidental(at tick: Tick, in measure: ScoreMeasure) -> Bool {
    measure.events.contains { $0.contains { $0.start == tick && $0.notes.contains { $0.accidental != nil } } }
  }

  /// Longer values get more room, but not in proportion (as engravers space them).
  private func spacing(for duration: Tick, at tick: Tick, in measure: ScoreMeasure) -> CGFloat {
    let length = Double(max(60, duration.rawValue))
    let base = space * CGFloat(2.6 + 1.5 * log2(length / 240))
    let extra = hasAccidental(at: tick, in: measure) ? space * 1.2 : 0
    return max(space * 2.2, base) + extra
  }

  // MARK: - Positions

  /// The y of a note's head (or a line) on a staff: half a space per step from the middle line.
  func y(diatonic: Int, staff: Int, in system: System) -> CGFloat {
    let clef = layout.staves[min(staff, layout.staves.count - 1)].clef
    let middle = system.staffTops[min(staff, system.staffTops.count - 1)] + space * 2
    return middle - CGFloat(diatonic - clef.middleLine) * space / 2
  }

  /// The diatonic step at a height on a staff.
  func diatonic(atY y: CGFloat, staff: Int, in system: System) -> Int {
    let clef = layout.staves[min(staff, layout.staves.count - 1)].clef
    let middle = system.staffTops[min(staff, system.staffTops.count - 1)] + space * 2
    return clef.middleLine + Int(((middle - y) / (space / 2)).rounded())
  }

  /// Which system, staff and bar a point is in.
  func locate(_ point: CGPoint) -> (system: Int, staff: Int, measure: Int)? {
    guard let systemIndex = systems.firstIndex(where: { point.y >= $0.top && point.y < $0.bottom + headroom * 0.5 }) else {
      return nil
    }
    let system = systems[systemIndex]
    let staff = system.staffTops.enumerated().min { abs($0.element + space * 2 - point.y) < abs($1.element + space * 2 - point.y) }?
      .offset ?? 0
    guard let measure = system.measures.firstIndex(where: { point.x >= $0.left && point.x < $0.right })
      ?? (point.x >= system.right ? system.measures.indices.last : nil)
    else { return nil }
    return (systemIndex, staff, measure)
  }

  /// The song position at an x in a bar, snapped to `grid` from the bar line.
  func tick(atX x: CGFloat, in measure: Measure, grid: Tick) -> Tick {
    var best = measure.measure.start
    var bestDistance = CGFloat.infinity
    var tick = measure.measure.start
    while tick < measure.measure.end {
      let distance = abs(measure.x(at: tick) - x)
      if distance < bestDistance {
        bestDistance = distance
        best = tick
      }
      tick = tick + grid
    }
    return best
  }

  /// Where a song position is drawn: its system and x.
  func place(_ tick: Tick) -> (system: Int, x: CGFloat)? {
    for (systemIndex, system) in systems.enumerated() {
      for measure in system.measures where tick >= measure.measure.start && tick < measure.measure.end {
        return (systemIndex, measure.x(at: tick))
      }
    }
    return nil
  }
}
