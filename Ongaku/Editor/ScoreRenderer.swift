//
//  ScoreRenderer.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// The colours a score is drawn in: light on the dark editor, black on white when printed.
struct ScorePalette {
  var ink: Color
  var staff: Color
  var selection: Color
  var faint: Color
  var playhead: Color

  static let screen = ScorePalette(
    ink: Color(white: 0.9), staff: Color(white: 0.55), selection: Theme.accent, faint: Color(white: 0.55), playhead: Theme.playhead)
  static let print = ScorePalette(ink: .black, staff: Color(white: 0.25), selection: .black, faint: Color(white: 0.4), playhead: .clear)
}

/// A note head placed on the page, for drawing and for clicking.
struct PlacedHead {
  var note: ScoreNote
  var event: ScoreEvent
  var center: CGPoint
  var system: Int
  var staff: Int
  var stemUp: Bool
}

extension EngravedScore {
  /// Whether an event's stem goes up: below the middle line it does (on a drum staff, always).
  func stemUp(_ notes: [ScoreNote], staff: Int) -> Bool {
    let clef = layout.staves[min(staff, layout.staves.count - 1)].clef
    guard clef != .percussion, !notes.isEmpty else { return true }
    let average = Double(notes.map(\.diatonic).reduce(0, +)) / Double(notes.count)
    return average < Double(clef.middleLine)
  }

  /// Every note head, where it's drawn.
  var placedHeads: [PlacedHead] {
    var heads: [PlacedHead] = []
    for (systemIndex, system) in systems.enumerated() {
      for measure in system.measures {
        for (staff, events) in measure.measure.events.enumerated() {
          let groups = Dictionary(grouping: events.filter { $0.beamGroup != nil }, by: { $0.beamGroup! })
          for event in events where !event.isRest {
            let up = stemUp(event.beamGroup.flatMap { groups[$0] }?.flatMap(\.notes) ?? event.notes, staff: staff)
            let x = measure.x(at: event.start)
            let sorted = event.notes.sorted { $0.diatonic < $1.diatonic }
            var previous: Int?
            var shifted = false
            for note in sorted {
              // A second in a chord goes on the other side of the stem.
              if let previous, note.diatonic - previous == 1, !shifted { shifted = true } else { shifted = false }
              let offset = shifted ? (up ? space * 1.15 : -space * 1.15) : 0
              let center = CGPoint(x: x + offset, y: y(diatonic: note.diatonic, staff: staff, in: system))
              heads.append(PlacedHead(note: note, event: event, center: center, system: systemIndex, staff: staff, stemUp: up))
              previous = note.diatonic
            }
          }
        }
      }
    }
    return heads
  }
}

/// Draws an engraved score.
struct ScoreRenderer {
  let score: EngravedScore
  let palette: ScorePalette
  var selected: Set<MIDINote.ID> = []
  var playhead: Tick?
  /// The selected notes are drawn moved by this while being dragged.
  var dragOffset: CGSize = .zero
  /// Whether the last system drawn ends the piece (a printed page may stop before it).
  var endsScore = true

  private var space: CGFloat { score.space }

  func draw(in context: GraphicsContext) {
    let heads = score.placedHeads
    for (index, system) in score.systems.enumerated() {
      drawStaves(system, isLast: endsScore && index == score.systems.count - 1, in: context)
      for measure in system.measures {
        drawHeader(measure, system: system, in: context)
        drawChordSymbols(measure, system: system, in: context)
        for (staff, events) in measure.measure.events.enumerated() {
          drawRests(events.filter(\.isRest), measure: measure, staff: staff, system: system, in: context)
        }
      }
      drawNotes(heads.filter { $0.system == index }, system: system, in: context)
    }
    drawTies(heads, in: context)
    drawPlayhead(in: context)
  }

  // MARK: Staves and headers

  private func line(_ from: CGPoint, _ to: CGPoint, width: CGFloat = 1, color: Color, in context: GraphicsContext) {
    context.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(color), lineWidth: width)
  }

  private func drawStaves(_ system: EngravedScore.System, isLast: Bool, in context: GraphicsContext) {
    for top in system.staffTops {
      for line in 0..<5 {
        let y = top + CGFloat(line) * space
        self.line(CGPoint(x: system.left, y: y), CGPoint(x: system.right, y: y), width: 0.8, color: palette.staff, in: context)
      }
    }
    guard let firstTop = system.staffTops.first, let lastTop = system.staffTops.last else { return }
    let bottom = lastTop + space * 4
    // The system's opening line, and a bracket joining a grand staff.
    line(CGPoint(x: system.left, y: firstTop), CGPoint(x: system.left, y: bottom), color: palette.ink, in: context)
    if system.staffTops.count > 1 {
      line(CGPoint(x: system.left - space * 0.6, y: firstTop), CGPoint(x: system.left - space * 0.6, y: bottom), width: space * 0.35,
        color: palette.ink, in: context)
    }
    // Bar lines, through both staves of a grand staff.
    for (index, measure) in system.measures.enumerated() {
      let isFinal = isLast && index == system.measures.count - 1
      line(CGPoint(x: measure.right, y: firstTop), CGPoint(x: measure.right, y: bottom), color: palette.ink, in: context)
      if isFinal {
        line(CGPoint(x: measure.right - space * 0.5, y: firstTop), CGPoint(x: measure.right - space * 0.5, y: bottom), color: palette.ink, in: context)
        context.fill(Path(CGRect(x: measure.right - space * 0.35, y: firstTop, width: space * 0.45, height: bottom - firstTop)), with: .color(palette.ink))
      }
    }
    // The bar number over the system.
    if let first = system.measures.first {
      context.draw(
        Text("\(first.measure.index + 1)").font(.system(size: space * 1.2)).foregroundStyle(palette.faint),
        at: CGPoint(x: system.left, y: firstTop - space * 1.6), anchor: .bottomLeading)
    }
  }

  private func drawHeader(_ measure: EngravedScore.Measure, system: EngravedScore.System, in context: GraphicsContext) {
    for (staff, top) in system.staffTops.enumerated() {
      let clef = score.layout.staves[staff].clef
      if measure.showsClef {
        let x = measure.left + space * 1.6
        switch clef {
        case .treble:
          context.draw(Text("\u{1D11E}").font(.custom("Apple Symbols", size: space * 6.4)).foregroundStyle(palette.ink),
            at: CGPoint(x: x, y: top + space * 2.15), anchor: .center)
        case .bass:
          context.draw(Text("\u{1D122}").font(.custom("Apple Symbols", size: space * 6.4)).foregroundStyle(palette.ink),
            at: CGPoint(x: x, y: top + space * 1.95), anchor: .center)
        case .percussion:
          for offset in [-0.35, 0.35] {
            context.fill(Path(CGRect(x: x + space * CGFloat(offset) - space * 0.2, y: top + space, width: space * 0.4, height: space * 2)),
              with: .color(palette.ink))
          }
        }
      }
      if measure.showsKey, clef != .percussion {
        let count = measure.measure.key.sharpsOrFlats
        let sharps = [38, 35, 39, 36, 33, 37, 34], flats = [34, 37, 33, 36, 32, 35, 31]
        let shift = clef == .bass ? -14 : 0
        for index in 0..<abs(count) {
          let diatonic = (count > 0 ? sharps[index] : flats[index]) + shift
          let y = score.y(diatonic: diatonic, staff: staff, in: system)
          context.draw(
            Text(count > 0 ? "♯" : "♭").font(.system(size: space * 2.6)).foregroundStyle(palette.ink),
            at: CGPoint(x: measure.keyX + space * (0.6 + CGFloat(index) * 1.05), y: y + (count > 0 ? 0 : -space * 0.35)), anchor: .center)
        }
      }
      if measure.showsTime {
        let signature = measure.measure.signature
        let font = Font.system(size: space * 2.3, weight: .heavy, design: .serif)
        let x = measure.timeX + space * 1.2
        context.draw(Text("\(signature.beatsPerBar)").font(font).foregroundStyle(palette.ink), at: CGPoint(x: x, y: top + space), anchor: .center)
        context.draw(Text("\(signature.beatUnit)").font(font).foregroundStyle(palette.ink), at: CGPoint(x: x, y: top + space * 3), anchor: .center)
      }
    }
  }

  private func drawChordSymbols(_ measure: EngravedScore.Measure, system: EngravedScore.System, in context: GraphicsContext) {
    guard let top = system.staffTops.first else { return }
    for symbol in measure.measure.chordSymbols {
      context.draw(
        Text(symbol.name).font(.system(size: space * 1.7, weight: .semibold)).foregroundStyle(palette.ink),
        at: CGPoint(x: measure.x(at: symbol.position), y: top - space * 3), anchor: .bottomLeading)
    }
  }

  // MARK: Rests

  private func drawRests(
    _ rests: [ScoreEvent], measure: EngravedScore.Measure, staff: Int, system: EngravedScore.System, in context: GraphicsContext
  ) {
    let top = system.staffTops[staff]
    for rest in rests {
      let x = measure.x(at: rest.start)
      let ink = GraphicsContext.Shading.color(palette.ink)
      switch rest.value.base {
      case .whole:
        // Hangs from the fourth line.
        context.fill(Path(CGRect(x: x - space * 0.6, y: top + space, width: space * 1.2, height: space * 0.5)), with: ink)
      case .half:
        // Sits on the middle line.
        context.fill(Path(CGRect(x: x - space * 0.6, y: top + space * 1.5, width: space * 1.2, height: space * 0.5)), with: ink)
      case .quarter:
        var path = Path()
        path.move(to: CGPoint(x: x - space * 0.25, y: top + space * 0.7))
        path.addLine(to: CGPoint(x: x + space * 0.35, y: top + space * 1.45))
        path.addLine(to: CGPoint(x: x - space * 0.25, y: top + space * 2.15))
        path.addLine(to: CGPoint(x: x + space * 0.35, y: top + space * 2.85))
        path.addQuadCurve(to: CGPoint(x: x, y: top + space * 3.4), control: CGPoint(x: x - space * 0.6, y: top + space * 2.8))
        context.stroke(path, with: ink, style: StrokeStyle(lineWidth: space * 0.28, lineCap: .round, lineJoin: .round))
      case .eighth, .sixteenth, .thirtySecond:
        let flags = rest.value.base.flags
        for flag in 0..<flags {
          let y = top + space * (1.5 + CGFloat(flag))
          context.fill(Path(ellipseIn: CGRect(x: x - space * 0.55, y: y - space * 0.25, width: space * 0.5, height: space * 0.5)), with: ink)
          line(CGPoint(x: x - space * 0.1, y: y + space * 0.1), CGPoint(x: x + space * 0.35, y: y - space * 0.3), width: space * 0.15,
            color: palette.ink, in: context)
        }
        line(CGPoint(x: x + space * 0.35, y: top + space * 1.2), CGPoint(x: x - space * 0.15, y: top + space * (2.6 + CGFloat(flags - 1))),
          width: space * 0.15, color: palette.ink, in: context)
      }
      if rest.value.dots > 0 {
        context.fill(Path(ellipseIn: CGRect(x: x + space * 0.8, y: top + space * 1.3, width: space * 0.35, height: space * 0.35)), with: ink)
      }
    }
  }

  // MARK: Notes

  private func color(for head: PlacedHead) -> Color {
    selected.contains(head.note.noteID) ? palette.selection : palette.ink
  }

  private func offset(for head: PlacedHead) -> CGSize {
    selected.contains(head.note.noteID) ? dragOffset : .zero
  }

  private func drawNotes(_ heads: [PlacedHead], system: EngravedScore.System, in context: GraphicsContext) {
    // Heads, accidentals, dots and ledger lines.
    for head in heads {
      let shift = offset(for: head)
      let center = CGPoint(x: head.center.x + shift.width, y: head.center.y + shift.height)
      let ink = color(for: head)
      drawLedgerLines(for: head, at: center, system: system, in: context)
      let width = space * 1.25, height = space * 0.95
      let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
      if head.note.isCross {
        line(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), width: space * 0.18, color: ink, in: context)
        line(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY), width: space * 0.18, color: ink, in: context)
      } else {
        var oval = context
        oval.translateBy(x: center.x, y: center.y)
        oval.rotate(by: .degrees(-20))
        let shape = Path(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        if head.event.value.base.rawValue >= 4 {
          oval.fill(shape, with: .color(ink))
        } else {
          oval.stroke(shape, with: .color(ink), lineWidth: space * (head.event.value.base == .whole ? 0.3 : 0.22))
        }
      }
      if let accidental = head.note.accidental {
        context.draw(
          Text(accidental.symbol).font(.system(size: space * 2.4)).foregroundStyle(ink),
          at: CGPoint(x: center.x - space * 1.5, y: center.y - (accidental == .flat ? space * 0.35 : 0)), anchor: .center)
      }
      if head.event.value.dots > 0 {
        let onLine = (head.note.diatonic - score.layout.staves[head.staff].clef.middleLine) % 2 == 0
        let dotY = center.y - (onLine ? space * 0.5 : 0)
        for dot in 0..<head.event.value.dots {
          context.fill(Path(ellipseIn: CGRect(
            x: center.x + space * (1.0 + CGFloat(dot) * 0.6), y: dotY - space * 0.17, width: space * 0.34, height: space * 0.34)), with: .color(ink))
        }
      }
    }

    // Stems, flags and beams, one event at a time.
    // Each staff is one voice, so an event is its staff and start.
    let events = Dictionary(grouping: heads, by: { "\($0.staff)-\($0.event.start.rawValue)" })
    var beamed: [String: [(head: [PlacedHead], x: CGFloat, end: CGFloat)]] = [:]
    for (_, group) in events.sorted(by: { $0.value[0].event.start < $1.value[0].event.start }) {
      let event = group[0].event
      guard event.value.base != .whole else { continue }
      let up = group[0].stemUp
      let shift = group.contains { selected.contains($0.note.noteID) } ? dragOffset : .zero
      let ys = group.map { $0.center.y + shift.height }
      let x = (group.map(\.center.x).min() ?? 0) + shift.width + (up ? space * 0.6 : -space * 0.6)
      let far = up ? (ys.min() ?? 0) - space * 3.4 : (ys.max() ?? 0) + space * 3.4
      if let beam = event.beamGroup {
        beamed["\(group[0].staff)-\(beam)", default: []].append((group, x, far))
      } else {
        let near = up ? (ys.max() ?? 0) : (ys.min() ?? 0)
        line(CGPoint(x: x, y: near), CGPoint(x: x, y: far), width: space * 0.13, color: color(for: group[0]), in: context)
        drawFlags(event.value.base.flags, x: x, tip: far, up: up, color: color(for: group[0]), in: context)
      }
    }
    for (_, members) in beamed {
      let sorted = members.sorted { $0.x < $1.x }
      guard let first = sorted.first, let last = sorted.last else { continue }
      let up = first.head[0].stemUp
      // A straight beam from the first stem to the last, gently sloped, clear of every head.
      var slope = sorted.count > 1 ? (last.end - first.end) / max(1, last.x - first.x) : 0
      slope = max(-0.25, min(0.25, slope))
      var startY = first.end
      for member in sorted {
        let y = startY + slope * (member.x - first.x)
        let heads = member.head.map(\.center.y)
        let limit = up ? (heads.min() ?? 0) - space * 2.6 : (heads.max() ?? 0) + space * 2.6
        if up, y > limit { startY -= y - limit }
        if !up, y < limit { startY += limit - y }
      }
      func beamY(_ x: CGFloat) -> CGFloat { startY + slope * (x - first.x) }
      for member in sorted {
        let ys = member.head.map(\.center.y)
        let near = up ? (ys.max() ?? 0) : (ys.min() ?? 0)
        line(CGPoint(x: member.x, y: near), CGPoint(x: member.x, y: beamY(member.x)), width: space * 0.13, color: color(for: member.head[0]), in: context)
      }
      let thickness = space * 0.5
      func beamPath(from x0: CGFloat, to x1: CGFloat, level: Int) -> Path {
        let shift = CGFloat(level) * space * 0.8 * (up ? 1 : -1)
        var path = Path()
        path.move(to: CGPoint(x: x0, y: beamY(x0) + shift))
        path.addLine(to: CGPoint(x: x1, y: beamY(x1) + shift))
        path.addLine(to: CGPoint(x: x1, y: beamY(x1) + shift + (up ? thickness : -thickness)))
        path.addLine(to: CGPoint(x: x0, y: beamY(x0) + shift + (up ? thickness : -thickness)))
        path.closeSubpath()
        return path
      }
      let ink = members.allSatisfy { $0.head.contains { selected.contains($0.note.noteID) } } ? palette.selection : palette.ink
      context.fill(beamPath(from: first.x, to: last.x, level: 0), with: .color(ink))
      // Second and third beams between neighbours that both have them; stubs otherwise.
      for level in 1..<3 {
        for (index, member) in sorted.enumerated() where member.head[0].event.value.base.flags > level {
          let next = index + 1 < sorted.count ? sorted[index + 1] : nil
          let previous = index > 0 ? sorted[index - 1] : nil
          if let next, next.head[0].event.value.base.flags > level {
            context.fill(beamPath(from: member.x, to: next.x, level: level), with: .color(ink))
          } else if previous.map({ $0.head[0].event.value.base.flags <= level }) ?? true {
            let toward: CGFloat = next != nil ? space * 1.2 : -space * 1.2
            context.fill(beamPath(from: min(member.x, member.x + toward), to: max(member.x, member.x + toward), level: level), with: .color(ink))
          }
        }
      }
      // Triplets get a 3 over (or under) the beam.
      if first.head[0].event.value.isTriplet {
        let mid = (first.x + last.x) / 2
        context.draw(Text("3").font(.system(size: space * 1.4, weight: .semibold).italic()).foregroundStyle(ink),
          at: CGPoint(x: mid, y: beamY(mid) + (up ? -space * 1.2 : space * 1.6)), anchor: .center)
      }
    }
    drawUnbeamedTriplets(heads, in: context)
  }

  private func drawFlags(_ count: Int, x: CGFloat, tip: CGFloat, up: Bool, color: Color, in context: GraphicsContext) {
    for flag in 0..<count {
      let start = tip + CGFloat(flag) * space * 0.8 * (up ? 1 : -1)
      var path = Path()
      path.move(to: CGPoint(x: x, y: start))
      path.addCurve(
        to: CGPoint(x: x + space * 0.9, y: start + space * 2.4 * (up ? 1 : -1)),
        control1: CGPoint(x: x + space * 0.2, y: start + space * 1.0 * (up ? 1 : -1)),
        control2: CGPoint(x: x + space * 1.3, y: start + space * 1.2 * (up ? 1 : -1)))
      context.stroke(path, with: .color(color), lineWidth: space * 0.22)
    }
  }

  /// A bracket and 3 over triplets that aren't beamed (quarters, or rests among them).
  private func drawUnbeamedTriplets(_ heads: [PlacedHead], in context: GraphicsContext) {
    let triplets = heads.filter { $0.event.value.isTriplet && $0.event.beamGroup == nil && $0.event.tupletGroup != nil }
    for (_, members) in Dictionary(grouping: triplets, by: { "\($0.staff)-\($0.event.tupletGroup!)" }) {
      let xs = members.map(\.center.x), ys = members.map(\.center.y)
      guard let minX = xs.min(), let maxX = xs.max(), let top = ys.min() else { continue }
      let y = top - space * 4.2
      var path = Path()
      path.move(to: CGPoint(x: minX - space * 0.5, y: y + space * 0.6))
      path.addLine(to: CGPoint(x: minX - space * 0.5, y: y))
      path.addLine(to: CGPoint(x: maxX + space * 0.8, y: y))
      path.addLine(to: CGPoint(x: maxX + space * 0.8, y: y + space * 0.6))
      context.stroke(path, with: .color(palette.ink), lineWidth: 0.8)
      context.draw(Text("3").font(.system(size: space * 1.4, weight: .semibold).italic()).foregroundStyle(palette.ink),
        at: CGPoint(x: (minX + maxX) / 2, y: y - space * 0.3), anchor: .bottom)
    }
  }

  private func drawLedgerLines(for head: PlacedHead, at center: CGPoint, system: EngravedScore.System, in context: GraphicsContext) {
    let middle = score.layout.staves[head.staff].clef.middleLine
    let distance = head.note.diatonic - middle
    guard abs(distance) >= 6 else { return }
    let direction = distance > 0 ? 1 : -1
    var step = 6
    while step <= abs(distance) {
      let y = score.y(diatonic: middle + step * direction, staff: head.staff, in: system) + (center.y - head.center.y)
      line(CGPoint(x: center.x - space * 1.0, y: y), CGPoint(x: center.x + space * 1.0, y: y), width: 0.9, color: palette.staff, in: context)
      step += 2
    }
  }

  // MARK: Ties and playhead

  private func drawTies(_ heads: [PlacedHead], in context: GraphicsContext) {
    var open: [String: PlacedHead] = [:]
    let ordered = heads.sorted { ($0.event.start, $0.center.x) < ($1.event.start, $1.center.x) }
    for head in ordered {
      let key = "\(head.staff)-\(head.note.pitch)"
      if head.note.isTiedFromPrevious, let from = open[key] {
        if from.system == head.system {
          tie(from: from.center, to: head.center, up: !from.stemUp, in: context)
        } else {
          let fromSystem = score.systems[from.system], toSystem = score.systems[head.system]
          tie(from: from.center, to: CGPoint(x: fromSystem.right - space, y: from.center.y), up: !from.stemUp, in: context)
          tie(from: CGPoint(x: toSystem.left + space * 4, y: head.center.y), to: head.center, up: !head.stemUp, in: context)
        }
        open[key] = nil
      }
      if head.note.tiesToNext { open[key] = head }
    }
  }

  private func tie(from: CGPoint, to: CGPoint, up: Bool, in context: GraphicsContext) {
    let direction: CGFloat = up ? -1 : 1
    let start = CGPoint(x: from.x + space * 0.7, y: from.y + direction * space * 0.6)
    let end = CGPoint(x: to.x - space * 0.7, y: to.y + direction * space * 0.6)
    let bulge = min(space * 1.2, max(space * 0.5, (end.x - start.x) * 0.12)) * direction
    var path = Path()
    path.move(to: start)
    path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + bulge * 1.6))
    path.addQuadCurve(to: start, control: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + bulge * 1.2))
    context.fill(path, with: .color(palette.ink))
  }

  private func drawPlayhead(in context: GraphicsContext) {
    guard let playhead, let place = score.place(playhead) else { return }
    let system = score.systems[place.system]
    guard let top = system.staffTops.first, let bottom = system.staffTops.last else { return }
    line(CGPoint(x: place.x, y: top - space * 2), CGPoint(x: place.x, y: bottom + space * 6), width: 1.5, color: palette.playhead, in: context)
  }
}
