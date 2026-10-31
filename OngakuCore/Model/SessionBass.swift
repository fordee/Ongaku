//
//  SessionBass.swift
//  OngakuCore
//

import Foundation

// The bass player. A bass player thinks in phrases: a groove that holds through the section,
// a variation, and a fill at the end of each four bars that leads into the next phrase. Notes
// come from the chord and the key (roots, fifths, octaves, thirds, sixths, sevenths, walk-ups
// and chromatic approach notes). Each style has its own vocabulary of one-bar figures; walking
// bass is worked out a beat at a time instead, as a line through the chords.

extension PlayerPerformance {
  /// How busy the figures are: 0 (simple) to 2 (busy).
  var level: Int { complexity < 0.34 ? 0 : complexity < 0.67 ? 1 : 2 }
}

/// A style's bass figures, by level. Each bar is written a sixteenth per character:
/// - `R` the root (a slash chord's bass note), `3` third, `5` fifth, `6` sixth, `7` seventh,
///   `b` flat seventh, `2` and `4` the scale's second and fourth, `8` the octave above the
///   root and `L` the fifth below it;
/// - `N` the next bar's root, early, tied over the bar line;
/// - `W` a scale step and `A` a half step, leading into the note after them (a run of them
///   walks or creeps into it);
/// - `x` a dead (muted) note; `-` holds the note before; `.` is a rest.
struct BassVocabulary {
  var grooves: [[String]]
  var variations: [[String]]
  var fills: [[String]]

  static let ending = "R-----------...."

  static func of(_ style: PlayerPerformance.Style) -> BassVocabulary {
    switch style {
    case .rootNotes:
      // Ballad and singer-songwriter bass: long roots, the push on the "and" of two, and a
      // pickup into the next phrase.
      BassVocabulary(
        grooves: [
          ["R---------------", "R-------R-------"],
          ["R-----R-R-------", "R-------5-------", "R-----R---------"],
          ["R-----R-R---5---", "R-----R-R-----R-", "R-------R-.R5---"],
        ],
        variations: [
          ["R-------R-------"],
          ["R-------R---5---", "R-----R-5-------"],
          ["R-----R-8---5---", "R-----R-R---5-R-"],
        ],
        fills: [
          ["R-----------A---"],
          ["R-------R---W-A-", "R-------5---A---"],
          ["R-----R-5---W-A-", "R-------5-6-W-A-"],
        ])

    case .drivingEighths:
      // Rock and pop: eighths pedalling the root, octave pops, gallops and walk-ups.
      BassVocabulary(
        grooves: [
          ["R-R-R-R-R-R-R-R-"],
          ["R-R-R-R-R-R-R-R-", "R-R-R-R-R-R-R-8-"],
          ["R-RRR-R-R-RRR-R-", "R-R-RRR-R-R-RRR-", "R-R-R-R-8-8-R-R-"],
        ],
        variations: [
          ["R-R-R-R-R-R-R-R-"],
          ["R-R-R-R-5-5-R-R-", "R-R-R-R-R-R-5-R-"],
          ["R-R-R-R-8-8-5-R-", "R-RRR-R-5-55R-R-"],
        ],
        fills: [
          ["R-R-R-R-R-R-R-A-"],
          ["R-R-R-R-R-R-W-A-", "R-R-R-R-5-5-W-A-"],
          ["R-R-R-R-8-b-5-A-", "R-R-R-R-R-WWW-A-"],
        ])

    case .funkBass:
      // Funk: a strong one, space, syncopated sixteenths, octave pops, dead notes and the flat
      // seventh; pentatonic runs for fills.
      BassVocabulary(
        grooves: [
          ["R--...x.R-.8....", "R--.....R-...b8."],
          ["R--.x.R.8..Rx.b.", "R.xR..8.x.R-.b8.", "R--x.R8.x.R..b-."],
          ["R.xRx.8.xR.b5x8.", "R.x8.xR.b.xR8x5.", "RxxR.x8xR.xbR8.x"],
        ],
        variations: [
          ["R--...x.R-.5...."],
          ["R--.x.R.8..Rx.5.", "R.xR..8.x.R-.5b."],
          ["R.xRx.8.xR.b8x5.", "R.x8.xR.5.xR8xb."],
        ],
        fills: [
          ["R--...x.8.b.5..."],
          ["R--.x.R.8.b.5.4.", "R.xR..8.b-5-4-A-"],
          ["R.xR8.b.5.4x3.A.", "R.x8b85.4b5.3xA."],
        ])

    case .motown:
      // Motown: melodic root–fifth–sixth–octave shapes, chromatic climbs and pushes ahead of
      // the beat.
      BassVocabulary(
        grooves: [
          ["R-----5-R-----N-", "R-------R-----5-"],
          ["R--.R-5-6-..8-A-", "R--5..R-8--.5-N-", "R-.R5-6-8---5-A-"],
          ["R-.R3-5-6-.58-A-", "R--R..5-8-.b8-N-"],
        ],
        variations: [
          ["R-----5-8-----N-"],
          ["R--.R-5-b-..8-A-", "R--5..R-3-5-6-A-"],
          ["R-.R3-5-b-.58-A-", "R-.L..R-3-.56-A-"],
        ],
        fills: [
          ["R-----5-6---W-A-"],
          ["R---5-6-b-8-W-A-", "R--.8-b-6-5-W-A-"],
          ["R-.R3-5-6-b-8-A-", "R-.8b-6-5-4-3-A-"],
        ])

    default:
      BassVocabulary(grooves: [["R---------------"]], variations: [["R---------------"]], fills: [["R---------------"]])
    }
  }

  /// A figure's notes: where each starts, its symbol and how many sixteenths it lasts.
  static func parse(_ figure: String) -> [(step: Int, symbol: Character, length: Int)] {
    var notes: [(step: Int, symbol: Character, length: Int)] = []
    var isHolding = false
    for (step, character) in figure.enumerated() {
      switch character {
      case "-": if isHolding, !notes.isEmpty { notes[notes.count - 1].length += 1 }
      case ".": isHolding = false
      default:
        notes.append((step, character, 1))
        isHolding = true
      }
    }
    return notes
  }
}

/// A key's scale, and the scale each chord's notes come from.
extension KeySignature {
  public var pitchClasses: Set<Int> {
    Set((mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]).map { (tonic + $0) % 12 })
  }
}

extension Chord {
  /// The chord's scale in a key, as semitones above its root: the mode the key gives it (so
  /// a passing note fits both), else the mode its quality suggests.
  public func scale(in key: Set<Int>) -> [Int] {
    func has(_ interval: Int) -> Bool { key.contains((root + interval) % 12) }
    switch quality {
    case .major, .major7, .six, .add9, .power:
      if quality == .power && !has(4) { return has(1) ? [0, 1, 3, 5, 7, 8, 10] : has(8) ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 3, 5, 7, 9, 10] }
      if has(11) || quality == .major7 { return has(6) ? [0, 2, 4, 6, 7, 9, 11] : [0, 2, 4, 5, 7, 9, 11] }
      return [0, 2, 4, 5, 7, 9, 10]
    case .dominant7, .dominant9, .sus2, .sus4:
      // Mixolydian, with the key's second and sixth (a minor key's V7 is Phrygian dominant).
      return [0, has(2) || !has(1) ? 2 : 1, 4, 5, 7, has(9) || !has(8) ? 9 : 8, 10]
    case .minor, .minor7, .minor9:
      return has(1) ? [0, 1, 3, 5, 7, 8, 10] : has(8) ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 3, 5, 7, 9, 10]
    case .minor6:
      return [0, 2, 3, 5, 7, 9, 10]
    case .diminished, .halfDiminished:
      return [0, 1, 3, 5, 6, 8, 10]
    case .augmented:
      return [0, 2, 4, 6, 8, 9, 11]
    }
  }
}

/// Plays the bass a bar at a time, remembering where the line is.
struct BassLine {
  typealias Event = PlayerPerformance.Event

  let player: PlayerPerformance
  let key: Set<Int>
  /// The bass's range, and the narrower range its roots sit in.
  let low: Int, high: Int, rootLow: Int, rootHigh: Int, center: Int

  private(set) var events: [Event] = []
  /// The last note played, the chord being played and where its root sits.
  private var last: Int?
  private var previous: Int?
  private var chord: Chord?
  private var root: Int?
  /// The next downbeat's note, chosen by the notes leading into it.
  private var planned: Int?
  /// A note pushed ahead of the bar line, and the pitch it holds into the next bar.
  private var tie: (index: Int, pitch: Int)?

  private static let sixteenth = Tick(240)

  init(player: PlayerPerformance, key: KeySignature) {
    self.player = player
    self.key = key.pitchClasses
    let octave = 12 * player.register
    (low, high, rootLow, rootHigh, center) = (28 + octave, 55 + octave, 28 + octave, 45 + octave, 36 + octave)
  }

  private var complexity: Double { min(max(player.complexity, 0), 1) }
  private var base: Double { 45 + min(max(player.loudness, 0), 1) * 70 }

  // MARK: - Notes

  /// A pitch class's note nearest `target`, within `range`.
  private func nearest(_ pitchClass: Int, to target: Int, in range: ClosedRange<Int>) -> Int {
    var best = pitchClass + 12 * ((target - pitchClass) / 12)
    for candidate in [best - 24, best - 12, best, best + 12, best + 24]
    where range.contains(candidate) && (abs(candidate - target) < abs(best - target) || !range.contains(best)) {
      best = candidate
    }
    return best
  }

  /// Where a chord's root (or slash bass) sits: near the last root, drawn toward the middle
  /// of the range so the line doesn't creep away.
  private func placeRoot(_ chord: Chord) -> Int {
    let near = root ?? last ?? center
    let candidates = stride(from: rootLow, through: rootHigh, by: 1).filter { $0 % 12 == chord.bassNote }
    return candidates.min { abs($0 - near) + abs($0 - center) / 3 < abs($1 - near) + abs($1 - center) / 3 }
      ?? nearest(chord.bassNote, to: center, in: low...high)
  }

  /// Moves to a chord: its root is the note the line was heading for, when that's the
  /// chord's bass note.
  private mutating func enter(_ newChord: Chord, landing: Int? = nil) {
    guard newChord != chord else { return }
    chord = newChord
    if let landing, landing % 12 == newChord.bassNote {
      root = landing
    } else {
      root = placeRoot(newChord)
    }
  }

  /// The note a figure's symbol plays over the current chord.
  private func pitch(_ symbol: Character) -> Int? {
    guard let chord, let root else { return nil }
    // Degrees count from the chord's root (below a slash chord's bass note).
    let chordRoot = root - ((chord.bassNote - chord.root) % 12 + 12) % 12
    let intervals = chord.quality.intervals
    let scale = chord.scale(in: key)
    var pitch: Int
    switch symbol {
    case "R", "x": pitch = root
    case "8": pitch = root + 12
    case "3": pitch = chordRoot + (intervals.contains(3) ? 3 : intervals.contains(4) ? 4 : scale[2])
    case "5": pitch = chordRoot + (intervals.contains(6) ? 6 : intervals.contains(8) ? 8 : 7)
    case "6": pitch = chordRoot + scale[5]
    case "7": pitch = chordRoot + (intervals.contains(10) ? 10 : intervals.contains(11) ? 11 : scale[6])
    case "b": pitch = chordRoot + (intervals.contains(11) ? 9 : 10)
    case "2": pitch = chordRoot + scale[1]
    case "4": pitch = chordRoot + scale[3]
    case "L": pitch = chordRoot - 5
    default: return nil
    }
    while pitch > high { pitch -= 12 }
    while pitch < low { pitch += 12 }
    return pitch
  }

  /// The notes leading into `target`: from the end, `A` a half step away and `W` a step of
  /// the key, from below when the line rises (or is level), else from above.
  private func approach(_ symbols: [Character], into target: Int, from previous: Int, below: Bool) -> [Int] {
    func run(_ below: Bool) -> [Int] {
      var pitches: [Int] = []
      var current = target
      for symbol in symbols.reversed() {
        if symbol == "A" {
          current += below ? -1 : 1
        } else {
          // The next note of the key, one or two semitones on.
          let steps = below ? [-1, -2] : [1, 2]
          current += steps.first { key.contains(((current + $0) % 12 + 12) % 12) } ?? steps[1]
        }
        pitches.insert(current, at: 0)
      }
      return pitches
    }
    let pitches = run(below)
    if pitches.contains(where: { $0 < low }) { return run(false) }
    if pitches.contains(where: { $0 > high }) { return run(true) }
    return pitches
  }

  private mutating func add(_ step: Int, of bar: PlayerPerformance.BarContext, pitch: Int, steps: Double, velocity: Double) {
    events.append(Event(
      position: bar.position(step), pitches: [pitch], length: Tick(Int64(Double(Self.sixteenth.rawValue) * steps)),
      velocity: velocity))
  }

  private mutating func played(_ pitch: Int) {
    previous = last
    last = pitch
  }

  // MARK: - Bars

  /// Plays a bar: the groove, a variation on the second bar of each phrase, a fill on the
  /// fourth (and on the region's last bar, leading out), or an ending.
  mutating func play(_ bar: PlayerPerformance.BarContext, barInRegion: Int) {
    let phrase = barInRegion / 4
    var random = SplitMix(seed: player.seed &+ UInt64(barInRegion + 1) &* 0xA24B_AED4_963E_E407)
    let isEnding = bar.isLastBar && !player.leadsIntoNext
    if player.style == .walking {
      walk(bar, isEnding: isEnding, random: &random)
      return
    }

    let vocabulary = BassVocabulary.of(player.style)
    let figure: String
    if isEnding {
      figure = BassVocabulary.ending
    } else if barInRegion % 4 == 3 || bar.isLastBar {
      var phraseRandom = SplitMix(seed: player.seed ^ UInt64(phrase + 1) &* 0x9E37_79B9_7F4A_7C15)
      figure = pick(vocabulary.fills[player.level], &phraseRandom)
    } else if barInRegion % 4 == 1 && complexity > 0.3 {
      var phraseRandom = SplitMix(seed: player.seed ^ UInt64(phrase + 7) &* 0x9E37_79B9_7F4A_7C15)
      figure = pick(vocabulary.variations[player.level], &phraseRandom)
    } else {
      // The groove holds through the region.
      var grooveRandom = SplitMix(seed: player.seed ^ 0x6A09_E667_F3BC_C908)
      figure = pick(vocabulary.grooves[player.level], &grooveRandom)
    }
    var notes = bar.fit(BassVocabulary.parse(figure))

    let nextChord = bar.chords.chord(at: bar.end)
    // Leaning into a chord change: the last note becomes an approach note, or a long note
    // makes room for one on the last "and".
    if !isEnding, let lastNote = notes.last, nextChord != bar.chord(at: bar.steps - 1),
      !["A", "W", "N"].contains(lastNote.symbol), random.unit() < complexity
    {
      if lastNote.step >= bar.steps - 4, lastNote.symbol != "x" {
        notes[notes.count - 1].symbol = "A"
      } else if lastNote.step + lastNote.length > bar.steps - 2, complexity > 0.35, bar.steps >= 8 {
        notes[notes.count - 1].length = bar.steps - 2 - lastNote.step
        notes.append((bar.steps - 2, "A", 2))
      }
    }
    // A chord that changes inside the bar gets its root where it starts.
    notes = bar.addingChordChanges(to: notes, symbol: "R")

    perform(notes, in: bar, nextChord: nextChord, random: &random)
  }

  private func pick(_ figures: [String], _ random: inout SplitMix) -> String {
    figures[Int(random.next() % UInt64(figures.count))]
  }

  /// Plays a bar's figure: works out each note, then the approach notes once the note they
  /// lead into is known.
  private mutating func perform(
    _ notes: [(step: Int, symbol: Character, length: Int)], in bar: PlayerPerformance.BarContext, nextChord: Chord,
    random: inout SplitMix
  ) {
    let tied = tie
    tie = nil
    // This bar's downbeat, as the last bar planned it; the next one is planned here.
    let landing = planned
    planned = nil
    var waiting: [(step: Int, symbol: Character, length: Int)] = []
    let articulation: Double = switch player.style {
    case .rootNotes: 0.95
    case .drivingEighths: 0.8
    case .funkBass: 0.72
    default: 0.88
    }

    func velocity(_ step: Int, _ symbol: Character) -> Double {
      var velocity = base
      if step == 0 {
        velocity += 8
      } else if bar.pulses.contains(where: { $0.step == step }) {
        velocity += 3
      } else if step % 2 == 1 {
        velocity -= 6
      } else if player.style == .drivingEighths {
        velocity -= 3
      }
      switch symbol {
      case "x": return base * 0.4
      case "8" where player.style == .funkBass: return velocity + 8
      case "A", "W": return velocity - 3
      default: return velocity
      }
    }

    /// Plays the approach notes waiting for `target`.
    func resolve(into target: Int) {
      guard !waiting.isEmpty else { return }
      let from = last ?? target
      let below = from == target ? random.unit() < 0.65 : from < target
      let pitches = approach(waiting.map(\.symbol), into: target, from: from, below: below)
      for (note, pitch) in zip(waiting, pitches) {
        add(note.step, of: bar, pitch: pitch, steps: Double(note.length) * 0.9, velocity: velocity(note.step, note.symbol))
        played(pitch)
      }
      waiting = []
    }

    /// The next downbeat's root, which the line heads for.
    func nextRoot() -> Int {
      if let planned { return planned }
      let pitch = nextChord == chord ? (root ?? center) : placeRoot(nextChord)
      planned = pitch
      return pitch
    }

    for note in notes {
      enter(bar.chord(at: note.step), landing: note.step == 0 ? landing : nil)
      if note.symbol == "A" || note.symbol == "W" {
        waiting.append(note)
        continue
      }
      let pitch: Int
      if note.symbol == "N" {
        pitch = nextRoot()
      } else if let resolved = self.pitch(note.symbol) {
        pitch = resolved
      } else {
        continue
      }
      resolve(into: pitch)
      // A note pushed over the bar line already sounds on the downbeat.
      if note.step == 0, let tied, tied.pitch == pitch {
        let held = notes.dropFirst().first.map { min($0.step, 4) } ?? 4
        events[tied.index].length = bar.start + Self.sixteenth * Int64(held) - events[tied.index].position
        continue
      }
      var steps = Double(note.length) * (note.length >= 3 ? max(articulation, 0.88) : articulation)
      if note.symbol == "x" { steps = 0.35 }
      if note.symbol == "N", note.step + note.length >= bar.steps {
        tie = (events.count, pitch)
        steps = Double(note.length + 2)
      }
      add(note.step, of: bar, pitch: pitch, steps: steps, velocity: velocity(note.step, note.symbol))
      if note.symbol != "x" { played(pitch) }
    }
    if !waiting.isEmpty { resolve(into: nextRoot()) }
  }

  // MARK: - Walking

  /// A walking line: a note a beat, landing on each new chord's root (or a chord tone when
  /// the chord carries on), stepping through the chord's scale in between, and leaning into
  /// each landing by a half step, a scale step or from its fifth. Simpler parts play in two
  /// (half notes); busier ones add skip notes, raked into the next beat.
  private mutating func walk(_ bar: PlayerPerformance.BarContext, isEnding: Bool, random: inout SplitMix) {
    let pulses = bar.pulses
    let inTwo = complexity < 0.3 && pulses.count % 2 == 0
    let beats: [(step: Int, length: Int)] = inTwo
      ? stride(from: 0, to: pulses.count, by: 2).map { (pulses[$0].step, pulses[$0].length + pulses[$0 + 1].length) }
      : pulses.map { ($0.step, $0.length) }
    if let landing = planned, !bar.chord(at: 0).pitchClasses.contains(landing % 12) { planned = nil }

    if isEnding {
      var step = 0
      while step < bar.steps {
        let next = bar.nextChange(after: step)
        enter(bar.chord(at: step))
        let pitch = step == 0 ? (planned ?? root ?? center) : (root ?? center)
        add(step, of: bar, pitch: pitch, steps: Double(next - step) * 0.95, velocity: base + 6)
        played(pitch)
        step = next
      }
      planned = nil
      return
    }

    var index = 0
    var target: Int? = planned
    planned = nil
    while index < beats.count {
      let segmentChord = bar.chord(at: beats[index].step)
      var end = index + 1
      while end < beats.count && bar.chord(at: beats[end].step) == segmentChord { end += 1 }
      let nextChord = end < beats.count ? bar.chord(at: beats[end].step) : bar.chords.chord(at: bar.end)

      // Land: on the planned note, or the new chord's root.
      let isNewChord = segmentChord != chord
      enter(segmentChord)
      let first = target ?? root ?? center
      if isNewChord, first % 12 == segmentChord.bassNote { root = first }
      emit(first, beat: beats[index], in: bar, accent: 6, isLast: end == index + 1 && end == beats.count, random: &random)

      // Where the line lands next: the next chord's root, or another note of this chord.
      let next: Int
      if nextChord != segmentChord {
        next = placeRoot(nextChord)
      } else {
        let tones = [segmentChord.bassNote, (segmentChord.root + (segmentChord.quality.isMinor ? 3 : 4)) % 12,
          (segmentChord.root + 7) % 12]
        let roll = random.unit()
        let tone = roll < 0.55 - complexity * 0.25 ? tones[0] : roll < 0.8 ? tones[1] : tones[2]
        next = nearest(tone, to: first, in: low...high)
      }

      let span = end - index
      let rising = first < center + 3 ? random.unit() < 0.75 : random.unit() < 0.25
      for beat in (index + 1)..<max(index + 1, end) {
        let previous = last ?? first
        let pitch: Int
        if beat == end - 1 && (!inTwo || random.unit() < 0.55) {
          pitch = lean(into: next, from: previous, random: &random)
        } else {
          // Through the scale toward the landing, arching away when it's near.
          let progress = Double(beat - index) / Double(span)
          let straight = Double(first) + Double(next - first) * progress
          let arch = max(0, 7 - Double(abs(next - first))) * 0.8 * sin(.pi * progress) * (rising ? 1 : -1)
          let ideal = straight + arch
          let scale = Set(segmentChord.scale(in: key).map { (segmentChord.root + $0) % 12 })
          let tones = segmentChord.pitchClasses
          let candidates = (max(low, previous - 7)...min(high, previous + 7)).filter {
            $0 != previous && scale.contains($0 % 12)
          }
          let scored = candidates.map {
            ($0, score($0, ideal: ideal, isChordTone: tones.contains($0 % 12), strong: beat % 2 == 0, random: &random))
          }
          pitch = scored.min { $0.1 < $1.1 }?.0 ?? nearest(segmentChord.root, to: previous, in: low...high)
        }
        emit(pitch, beat: beats[beat], in: bar, accent: 0, isLast: beat == beats.count - 1, random: &random)
      }
      target = end < beats.count ? next : nil
      if end == beats.count { planned = next }
      index = end
    }
  }

  private func score(_ pitch: Int, ideal: Double, isChordTone: Bool, strong: Bool, random: inout SplitMix) -> Double {
    var score = abs(Double(pitch) - ideal)
    if isChordTone && strong { score -= 1 }
    if pitch == previous { score += 1.5 }
    return score + random.unit() * 1.2
  }

  /// The note before a landing: a half step below or above it, the scale step on the way, or
  /// its fifth (as a dominant leads home).
  private func lean(into target: Int, from previous: Int, random: inout SplitMix) -> Int {
    let stepPitch = approach(["W"], into: target, from: previous, below: previous < target)[0]
    let options: [(pitch: Int, weight: Double)] = [
      (target - 1, 0.35), (target + 1, 0.25), (stepPitch, 0.25), (nearest((target + 7) % 12, to: previous, in: low...high), 0.15),
    ].filter { $0.pitch != previous && $0.pitch != target && (low...high).contains($0.pitch) }
    guard !options.isEmpty else { return target - 1 }
    var roll = random.unit() * options.reduce(0) { $0 + $1.weight }
    for option in options {
      roll -= option.weight
      if roll <= 0 { return option.pitch }
    }
    return options[options.count - 1].pitch
  }

  /// A walking note; busier parts sometimes rake a ghost of it on the (swung) "and".
  private mutating func emit(
    _ pitch: Int, beat: (step: Int, length: Int), in bar: PlayerPerformance.BarContext, accent: Double, isLast: Bool,
    random: inout SplitMix
  ) {
    let skips = complexity > 0.55 && beat.length >= 4 && !isLast && random.unit() < (complexity - 0.5) * 0.7
    let half = beat.length / 2
    add(beat.step, of: bar, pitch: pitch, steps: Double(skips ? half : beat.length) * 0.92,
      velocity: base + accent + (beat.step == 0 ? 2 : 0))
    if skips {
      add(beat.step + half, of: bar, pitch: pitch, steps: 0.6, velocity: base * 0.45)
    }
    played(pitch)
  }
}

extension PlayerPerformance.BarContext {
  /// Fits a 4/4 figure to the bar's beats: each beat of the bar takes a beat of the figure
  /// (the last beat takes the figure's fourth, where its pickups are), and a beat of three
  /// eighths spreads the figure's sixteenths across them.
  func fit(_ figure: [(step: Int, symbol: Character, length: Int)]) -> [(step: Int, symbol: Character, length: Int)] {
    if pulses.count == 4, pulses.allSatisfy({ $0.length == 4 }) { return figure }
    var placed: [(step: Int, symbol: Character, length: Int)] = []
    for (index, pulse) in pulses.enumerated() {
      let beat = index == pulses.count - 1 ? 3 : index < 3 ? index : 1 + index % 2
      for note in figure where note.step / 4 == beat {
        let sub = note.step % 4
        let offset = pulse.length == 6 ? [0, 2, 4, 5][sub] : sub * pulse.length / 4
        let length = max(1, (note.length * pulse.length + 2) / 4)
        placed.append((pulse.step + offset, note.symbol, length))
      }
    }
    // Notes last until the next one.
    for index in placed.indices {
      let next = index + 1 < placed.count ? placed[index + 1].step : steps
      placed[index].length = max(1, min(placed[index].length, next - placed[index].step))
    }
    return placed
  }
}
