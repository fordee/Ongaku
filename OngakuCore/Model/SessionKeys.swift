//
//  SessionKeys.swift
//  OngakuCore
//

import Foundation

// The keyboard player. Like the bass player it plays in phrases (a groove for the section, a
// variation, and a turnaround into each new phrase), with a figure for each hand. Chords are
// voiced as a keyboard player would: with the colour the style likes (ninths, sevenths,
// sixths, from the key), each voicing moving as little as it can from the last, and the root
// left to the left hand.

/// One bar for each hand, a sixteenth per character.
/// - Right hand: `C` the chord, `c` a soft, short chord, `V` the chord voiced again (its top
///   note moving), `S` its sus4, `N` the next bar's chord early (tied over the bar line), `T`
///   the top note alone, and `1`–`4` one note of the chord from the bottom (broken chords).
/// - Left hand: `R` the root, `O` the root and its octave, `5` the fifth, `8` the octave, `9`
///   the ninth, `t` the tenth, `N` the next bar's root early.
/// - Both: `-` holds the note before; `.` is a rest.
struct KeysFigure {
  var right: String
  var left: String

  init(_ right: String, _ left: String = "................") {
    self.right = right
    self.left = left
  }
}

struct KeysVocabulary {
  var grooves: [[KeysFigure]]
  var variations: [[KeysFigure]]
  var fills: [[KeysFigure]]
  var ending = KeysFigure("C---------------", "O---------------")

  static func of(_ style: PlayerPerformance.Style) -> KeysVocabulary {
    typealias F = KeysFigure
    switch style {
    case .pad:
      // Held chords, re-voiced as they go so the top line moves, with sus4s resolving into
      // each new phrase.
      return KeysVocabulary(
        grooves: [
          [F("C---------------", "R---------------")],
          [F("C---------------", "O---------------"), F("C-------V-------", "O---------------")],
          [F("C-------V-------", "O-------5-------"), F("C-----V---------", "O---------------")],
        ],
        variations: [
          [F("C---------------", "R---------------")],
          [F("C-----------V---", "O---------------")],
          [F("C---V-------V---", "O-------5-------")],
        ],
        fills: [
          [F("C-------S-------", "R---------------")],
          [F("C-------S---C---", "O---------------")],
          [F("C-------S-C-V---", "O-------5-------"), F("C-----V-S---C-N-", "O-----------....")],
        ])

    case .blockChords:
      // Piano chords on the beat over left-hand octaves, pushing into the changes.
      return KeysVocabulary(
        grooves: [
          [F("C---C---C---C---", "O-------O-------")],
          [F("C---C---C---C-C-", "O-------5-------"), F("C---C---C-C-C---", "O-------O-------")],
          [F("C---C-C-C---C-C-", "O-----R-O-------"), F("C-C-C---C-C-C---", "O-------O---5---")],
        ],
        variations: [
          [F("C-------C---C---", "O-------O-------")],
          [F("C---C---C-C-C-C-", "O-------5-------")],
          [F("C---C-C-C-C-C-C-", "O-----R-O---5---")],
        ],
        fills: [
          [F("C---C---C-----N-", "O-------O-----N-")],
          [F("C---C---S---C-N-", "O-------5-----N-"), F("C---C---C-C-T-N-", "O-------O-----N-")],
          [F("C---C-C-S-C-T-N-", "O-----R-O-5---N-")],
        ])

    case .popPulse:
      // Pop piano: driving eighths, the 3-3-2 push, soft in-between chords and anticipations.
      return KeysVocabulary(
        grooves: [
          [F("C-C-C-C-C-C-C-C-", "R-------R-------")],
          [F("C--C--C-C--C--C-", "R--R--R-R-------"), F("C-c-C-c-C-c-C-c-", "R-------R---5---")],
          [F("C-cC-cC-C-cC-cC-", "R--R--R-R--R--R-"), F("CcC-cCc-CcC-cCc-", "R-------R-------")],
        ],
        variations: [
          [F("C-C-C-C-C-C-C-C-", "R-------5-------")],
          [F("C--C--C-C-C-C-C-", "R--R--R-R-------")],
          [F("C-cC-cC-C-cC-C-c", "R--R--R-R--R--R-")],
        ],
        fills: [
          [F("C-C-C-C-C-C-C-N-", "R-------R-----N-")],
          [F("C--C--C-C--C--N-", "R--R--R-R-----N-"), F("C-c-C-c-S-c-C-N-", "R-------R-----N-")],
          [F("C-cC-cC-S-cS-CN-", "R--R--R-R--R--N-")],
        ])

    case .balladArpeggio:
      // Ballad piano: the left hand rolling root–fifth–octave–ninth–tenth under the pedal,
      // the right hand holding the chord and breaking it as the part gets busier.
      return KeysVocabulary(
        grooves: [
          [F("C---------------", "R---5---8---5---")],
          [F("C---------------", "R-5-8-9-t-9-8-5-"), F("C-------T-------", "R-5-8-5-R-5-8-5-")],
          [F("C-------1-2-3-4-", "R-5-8-9-t-9-8-5-"), F("C---3-2-T---3-2-", "R-5-8-9-t-9-8-5-")],
        ],
        variations: [
          [F("C---------------", "R---5---8---9---")],
          [F("C-------T---3---", "R-5-8-9-t-9-8-5-")],
          [F("C-------4-3-2-1-", "R-5-8-9-t-9-8-5-")],
        ],
        fills: [
          [F("C-------S-------", "R---5---8---5---")],
          [F("C-------S---C---", "R-5-8-9-t-9-8-N-")],
          [F("C-------4-3-2-N-", "R-5-8-9-t-9-8-N-")],
        ])

    case .funkStabs:
      // Funk keys: short, syncopated ninth and minor-seventh stabs with soft chanks in
      // between; the bass has the low end.
      return KeysVocabulary(
        grooves: [
          [F("....C-......C-.."), F("..C.....C-..C...")],
          [F("C..C..C...C.C-.."), F("..cC..C...cC..C."), F("C.c.C-.cC.c.C-.c")],
          [F("CccCc.CcC.cCc.Cc"), F("C.cC.cC.cC.cC-cC")],
        ],
        variations: [
          [F("....C-......C.C.")],
          [F("C..C..C...C.S-.."), F("..cC..C...cC.S..")],
          [F("CccCc.CcS.cSc.Cc")],
        ],
        fills: [
          [F("....C-......C.N.")],
          [F("C..C..C...C.C.N."), F("..cC..C.S.cS..N.")],
          [F("CccCc.CcS.C.C.N.")],
        ],
        ending: F("C-.............."))

    default:
      return KeysVocabulary(grooves: [[F("C---------------")]], variations: [[F("C---------------")]], fills: [[F("C---------------")]])
    }
  }
}

/// Plays the keys a bar at a time, remembering the last voicing.
struct KeysLine {
  typealias Event = PlayerPerformance.Event
  typealias Note = (step: Int, symbol: Character, length: Int)

  let player: PlayerPerformance
  let key: Set<Int>
  /// The right hand's range and middle, and the left hand's roots.
  let low: Int, high: Int, center: Int, leftLow: Int

  private(set) var events: [Event] = []
  private var voicing: [Int] = []
  private var voiced: Chord?
  private var leftChord: Chord?
  private var leftRoot: Int?
  /// Chords pushed ahead of the bar line, holding into the next bar.
  private var rightTie: (index: Int, chord: Chord)?
  private var leftTie: (index: Int, chord: Chord)?

  private static let sixteenth = Tick(240)

  init(player: PlayerPerformance, key: KeySignature) {
    self.player = player
    self.key = key.pitchClasses
    let octave = 12 * player.register
    (low, high, center, leftLow) = (52 + octave, 81 + octave, 66 + octave, 36 + octave)
  }

  private var complexity: Double { min(max(player.complexity, 0), 1) }
  private var base: Double { 45 + min(max(player.loudness, 0), 1) * 70 }

  // MARK: - Voicings

  /// The pitch classes the right hand plays for a chord: the chord with the colour the style
  /// likes, from the chord's scale in the key.
  func tones(for chord: Chord) -> [Int] {
    let scale = chord.scale(in: key)
    var intervals = chord.quality.intervals.map { $0 % 12 }
    let isTriad = chord.quality == .major || chord.quality == .minor
    // A ninth a whole step up (a flat ninth would clash).
    let ninth = scale[1] == 2
    let level = player.level
    switch player.style {
    case .pad:
      if isTriad, level >= 1, ninth { intervals.append(2) }
      if isTriad, level >= 2 { intervals.append(scale[6]) }
    case .popPulse, .balladArpeggio:
      if chord.quality == .major, level >= 1, ninth { intervals.append(2) }
    case .funkStabs:
      switch chord.quality {
      case .minor:
        intervals += level >= 1 && ninth ? [10, 2] : [10]
      case .major:
        // A major chord with a flat seventh in its scale is a dominant: a ninth chord.
        intervals += scale[6] == 10 ? [10, 2] : [9, 2]
      case .dominant7:
        if level >= 1, ninth { intervals.append(2) }
        if level >= 2 { intervals.append(9) }
      default:
        break
      }
      // Funk voicings leave out the fifth.
      if intervals.count > 4 { intervals.removeAll { $0 == 7 } }
    default:
      break
    }
    var unique: [Int] = []
    for interval in intervals where !unique.contains(interval) { unique.append(interval) }
    // Big pad voicings and funk stabs leave the root to the left hand or the bass.
    if (player.style == .pad && unique.count >= 5) || (player.style == .funkStabs && unique.count >= 4) {
      unique.removeAll { $0 == 0 }
    }
    return unique.map { (chord.root + $0) % 12 }
  }

  /// A sus4: the third up to the fourth.
  private func suspended(_ tones: [Int], of chord: Chord) -> [Int] {
    let third = chord.quality.intervals.first { $0 == 3 || $0 == 4 }.map { (chord.root + $0) % 12 }
    guard let third else { return tones }
    return tones.map { $0 == third ? (chord.root + 5) % 12 : $0 }
  }

  /// Every way to voice the pitch classes in the right hand's range: each inversion in close
  /// position and, for held chords, spread (the second note from the top dropped an octave).
  private func voicings(_ pitchClasses: [Int], root: Int) -> [[Int]] {
    let ordered = pitchClasses.sorted { (($0 - root) % 12 + 12) % 12 < (($1 - root) % 12 + 12) % 12 }
    guard !ordered.isEmpty else { return [] }
    var results: [[Int]] = []
    let spreads = ordered.count >= 4 && [.pad, .balladArpeggio].contains(player.style)
    for rotation in 0..<ordered.count {
      let classes = Array(ordered[rotation...] + ordered[..<rotation])
      for octave in 3...6 {
        var pitches: [Int] = []
        var pitch = classes[0] + 12 * octave
        for pitchClass in classes {
          while ((pitch % 12) + 12) % 12 != pitchClass { pitch += 1 }
          pitches.append(pitch)
          pitch += 1
        }
        var shapes = [pitches]
        if spreads {
          var dropped = pitches
          dropped[dropped.count - 2] -= 12
          shapes.append(dropped.sorted())
        }
        for shape in shapes where shape.first! >= low && shape.last! <= high { results.append(shape) }
      }
    }
    return results
  }

  /// How far a voicing is from the last one (each voice's move, the top line's move most),
  /// and from the middle of the keyboard; close, muddy or clashing shapes cost more.
  private func cost(_ shape: [Int], after previous: [Int]) -> Double {
    let mean = Double(shape.reduce(0, +)) / Double(shape.count)
    var cost = 0.3 * abs(mean - Double(center))
    if !previous.isEmpty {
      let previousMean = Double(previous.reduce(0, +)) / Double(previous.count)
      cost += shape.count == previous.count
        ? Double(zip(shape, previous).reduce(0) { $0 + abs($1.0 - $1.1) })
        : abs(mean - previousMean) * Double(shape.count)
      cost += 0.6 * Double(abs(shape.last! - previous.last!))
    }
    if shape.count >= 2, shape[shape.count - 1] - shape[shape.count - 2] <= 1 { cost += 4 }
    if shape[0] < 57, shape.count >= 2, shape[1] - shape[0] <= 3 { cost += 3 }
    return cost
  }

  /// The chord's voicing nearest the last one.
  private mutating func voice(_ pitchClasses: [Int], of chord: Chord) -> [Int] {
    let shapes = voicings(pitchClasses, root: chord.root)
    voicing = shapes.min { cost($0, after: voicing) < cost($1, after: voicing) } ?? pitchClasses.map { $0 + 60 }
    voiced = chord
    return voicing
  }

  /// The chord voiced again with a different top note, rising if it can.
  private mutating func revoice(_ pitchClasses: [Int], of chord: Chord) -> [Int] {
    let current = voicing
    let shapes = voicings(pitchClasses, root: chord.root).filter { $0.last != current.last }
    guard !shapes.isEmpty, let top = current.last else { return voice(pitchClasses, of: chord) }
    func revoiceCost(_ shape: [Int]) -> Double { cost(shape, after: current) + (shape.last! < top ? 2 : 0) }
    voicing = shapes.min { revoiceCost($0) < revoiceCost($1) } ?? current
    voiced = chord
    return voicing
  }

  /// The left hand's root for a chord, near the last one.
  private mutating func leftHandRoot(_ chord: Chord) -> Int {
    if chord == leftChord, let leftRoot { return leftRoot }
    let near = leftRoot ?? leftLow + 5
    let candidates = [leftLow + ((chord.bassNote - leftLow) % 12 + 12) % 12]
    var root = candidates[0]
    if abs(root + 12 - near) < abs(root - near), root + 12 <= leftLow + 14 { root += 12 }
    leftChord = chord
    leftRoot = root
    return root
  }

  // MARK: - Bars

  /// Plays a bar: the groove, a variation on the second bar of each phrase, a turnaround on
  /// the fourth (and the region's last bar, leading out), or an ending.
  mutating func play(_ bar: PlayerPerformance.BarContext, barInRegion: Int) {
    let phrase = barInRegion / 4
    var random = SplitMix(seed: player.seed &+ UInt64(barInRegion + 1) &* 0xD1B5_4A32_D192_ED03)
    let isEnding = bar.isLastBar && !player.leadsIntoNext
    let vocabulary = KeysVocabulary.of(player.style)
    let level = player.level
    let figure: KeysFigure
    if isEnding {
      figure = vocabulary.ending
    } else if barInRegion % 4 == 3 || bar.isLastBar {
      var phraseRandom = SplitMix(seed: player.seed ^ UInt64(phrase + 1) &* 0x9E37_79B9_7F4A_7C15)
      figure = pick(vocabulary.fills[level], &phraseRandom)
    } else if barInRegion % 4 == 1 && complexity > 0.3 {
      var phraseRandom = SplitMix(seed: player.seed ^ UInt64(phrase + 7) &* 0x9E37_79B9_7F4A_7C15)
      figure = pick(vocabulary.variations[level], &phraseRandom)
    } else {
      var grooveRandom = SplitMix(seed: player.seed ^ 0xBB67_AE85_84CA_A73B)
      figure = pick(vocabulary.grooves[level], &grooveRandom)
    }
    var right = bar.fit(BassVocabulary.parse(figure.right))
    var left = bar.fit(BassVocabulary.parse(figure.left))
    let nextChord = bar.chords.chord(at: bar.end)

    // Busier parts push the last chord of the bar into a chord change.
    if !isEnding, [.blockChords, .popPulse, .funkStabs].contains(player.style),
      nextChord != bar.chord(at: bar.steps - 1), let last = right.last, "Cc".contains(last.symbol),
      last.step >= bar.steps - 2, random.unit() < complexity * 0.8
    {
      right[right.count - 1].symbol = "N"
    }
    right = bar.addingChordChanges(to: right, symbol: "C")
    if !left.isEmpty { left = bar.addingChordChanges(to: left, symbol: "R") }

    playRight(right, in: bar, nextChord: nextChord)
    playLeft(left, in: bar, nextChord: nextChord)
  }

  private func pick(_ figures: [KeysFigure], _ random: inout SplitMix) -> KeysFigure {
    figures[Int(random.next() % UInt64(figures.count))]
  }

  private func velocity(_ step: Int, in bar: PlayerPerformance.BarContext) -> Double {
    var velocity = base * (player.style == .pad ? 0.82 : 1)
    if step == 0 {
      velocity += 8
    } else if bar.pulses.contains(where: { $0.step == step }) {
      velocity += 3
    } else if step % 2 == 1 {
      velocity -= 5
    }
    return velocity
  }

  /// How long a note sounds, in sixteenths: ballad notes ring (under the pedal) until the
  /// chord changes; others by the style's touch.
  private func sounding(_ note: Note, in bar: PlayerPerformance.BarContext) -> Double {
    switch player.style {
    case .balladArpeggio: Double(bar.nextChange(after: note.step) - note.step) * 0.98
    case .pad: Double(note.length) * 0.98
    case .blockChords: Double(note.length) * 0.85
    case .popPulse: Double(note.length) * (note.length >= 3 ? 0.9 : 0.7)
    case .funkStabs: Double(note.length) * 0.5
    default: Double(note.length) * 0.9
    }
  }

  private mutating func add(_ step: Int, of bar: PlayerPerformance.BarContext, pitches: [Int], steps: Double, velocity: Double) {
    events.append(Event(
      position: bar.position(step), pitches: pitches, length: Tick(Int64(Double(Self.sixteenth.rawValue) * steps)),
      velocity: velocity))
  }

  /// Holds a chord pushed over the bar line through the downbeat, to the bar's next note.
  private mutating func hold(_ index: Int, through notes: [Note], in bar: PlayerPerformance.BarContext) {
    let held = notes.dropFirst().first.map { min($0.step, 8) } ?? 8
    events[index].length = bar.start + Self.sixteenth * Int64(held) - events[index].position
  }

  private mutating func playRight(_ notes: [Note], in bar: PlayerPerformance.BarContext, nextChord: Chord) {
    let tied = rightTie
    rightTie = nil
    for note in notes {
      let chord = bar.chord(at: note.step)
      var steps = sounding(note, in: bar)
      var velocity = velocity(note.step, in: bar)
      let pitches: [Int]
      switch note.symbol {
      case "C", "c", "V", "S", "N":
        let target = note.symbol == "N" ? nextChord : chord
        if note.step == 0, note.symbol == "C", let tied, tied.chord == chord {
          hold(tied.index, through: notes, in: bar)
          continue
        }
        var tones = tones(for: target)
        if note.symbol == "S" { tones = suspended(tones, of: target) }
        pitches = note.symbol == "V" ? revoice(tones, of: target) : voice(tones, of: target)
        if note.symbol == "c" {
          velocity *= 0.6
          steps = min(steps, 0.6)
        }
        // A chord pushed onto the last sixteenth holds over the bar line (a funk stab stays short).
        if note.symbol == "N", note.step + note.length >= bar.steps, player.style != .funkStabs {
          rightTie = (events.count, nextChord)
          steps = Double(note.length + 2)
        }
      case "T", "1", "2", "3", "4":
        if voiced != chord || voicing.isEmpty { _ = voice(tones(for: chord), of: chord) }
        let index = note.symbol == "T" ? voicing.count - 1 : min(Int(String(note.symbol))! - 1, voicing.count - 1)
        pitches = [voicing[index]]
        velocity *= note.symbol == "T" ? 0.95 : 0.82
      default:
        continue
      }
      add(note.step, of: bar, pitches: pitches, steps: steps, velocity: velocity)
    }
  }

  private mutating func playLeft(_ notes: [Note], in bar: PlayerPerformance.BarContext, nextChord: Chord) {
    let tied = leftTie
    leftTie = nil
    for note in notes {
      let chord = note.symbol == "N" ? nextChord : bar.chord(at: note.step)
      if note.step == 0, let tied, tied.chord == chord, "RO".contains(note.symbol) {
        hold(tied.index, through: notes, in: bar)
        continue
      }
      let root = leftHandRoot(chord)
      let third = chord.quality.intervals.first { $0 == 3 || $0 == 4 } ?? 4
      let pitches: [Int] = switch note.symbol {
      case "O": [root, root + 12]
      case "5": [root + (chord.quality.intervals.contains(6) ? 6 : 7)]
      case "8": [root + 12]
      case "9": [root + 14]
      case "t": [root + 12 + third]
      default: [root]
      }
      var steps = sounding(note, in: bar)
      if note.symbol == "N", note.step + note.length >= bar.steps {
        leftTie = (events.count, nextChord)
        steps = Double(note.length + 2)
      }
      add(note.step, of: bar, pitches: pitches, steps: steps, velocity: velocity(note.step, in: bar) - 6)
    }
  }
}

extension PlayerPerformance.BarContext {
  /// A figure with a note added where a chord changes inside the bar and the figure has
  /// none, cutting short the note sounding there.
  func addingChordChanges(to notes: [(step: Int, symbol: Character, length: Int)], symbol: Character)
    -> [(step: Int, symbol: Character, length: Int)]
  {
    var notes = notes
    for change in 1..<max(1, steps) where chord(at: change) != chord(at: change - 1) {
      guard !notes.contains(where: { $0.step == change }) else { continue }
      let after = notes.firstIndex { $0.step > change } ?? notes.count
      if after > 0, notes[after - 1].step + notes[after - 1].length > change {
        let end = notes[after - 1].step + notes[after - 1].length
        notes[after - 1].length = change - notes[after - 1].step
        notes.insert((change, symbol, end - change), at: after)
      } else {
        notes.insert((change, symbol, min(4, (after < notes.count ? notes[after].step : steps) - change)), at: after)
      }
    }
    return notes
  }
}
