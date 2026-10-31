//
//  Chords.swift
//  OngakuCore
//

import Foundation

/// A chord: its root, its quality and, for slash chords, a different bass note. Written and
/// read the usual way ("Am7", "F♯m7♭5", "C/E").
public struct Chord: Codable, Sendable, Hashable, CustomStringConvertible {
  public enum Quality: String, Codable, Sendable, CaseIterable, Identifiable {
    case major, minor, dominant7, major7, minor7, diminished, halfDiminished, augmented, sus2, sus4
    case six, minor6, add9, dominant9, minor9, power

    public var id: Self { self }

    /// Semitones above the root.
    public var intervals: [Int] {
      switch self {
      case .major: [0, 4, 7]
      case .minor: [0, 3, 7]
      case .dominant7: [0, 4, 7, 10]
      case .major7: [0, 4, 7, 11]
      case .minor7: [0, 3, 7, 10]
      case .diminished: [0, 3, 6]
      case .halfDiminished: [0, 3, 6, 10]
      case .augmented: [0, 4, 8]
      case .sus2: [0, 2, 7]
      case .sus4: [0, 5, 7]
      case .six: [0, 4, 7, 9]
      case .minor6: [0, 3, 7, 9]
      case .add9: [0, 4, 7, 14]
      case .dominant9: [0, 4, 7, 10, 14]
      case .minor9: [0, 3, 7, 10, 14]
      case .power: [0, 7]
      }
    }

    /// What follows the root in the chord's name.
    public var suffix: String {
      switch self {
      case .major: ""
      case .minor: "m"
      case .dominant7: "7"
      case .major7: "maj7"
      case .minor7: "m7"
      case .diminished: "dim"
      case .halfDiminished: "m7♭5"
      case .augmented: "aug"
      case .sus2: "sus2"
      case .sus4: "sus4"
      case .six: "6"
      case .minor6: "m6"
      case .add9: "add9"
      case .dominant9: "9"
      case .minor9: "m9"
      case .power: "5"
      }
    }

    /// The third, if it has one (for players choosing passing notes): major or minor.
    public var isMinor: Bool { intervals.contains(3) }
  }

  /// Pitch class of the root, 0 (C) through 11 (B).
  public var root: Int
  public var quality: Quality
  /// For a slash chord, the bass note's pitch class.
  public var bass: Int?

  public init(root: Int, quality: Quality = .major, bass: Int? = nil) {
    let root = ((root % 12) + 12) % 12
    let bass = bass.map { (($0 % 12) + 12) % 12 }
    self.root = root
    self.quality = quality
    // A "slash" bass that's the root is just the chord.
    self.bass = bass == root ? nil : bass
  }

  /// The pitch classes in the chord (the bass too, for a slash chord).
  public var pitchClasses: Set<Int> {
    var classes = Set(quality.intervals.map { (root + $0) % 12 })
    if let bass { classes.insert(bass) }
    return classes
  }

  /// The lowest note a bass player would play: the slash bass, or the root.
  public var bassNote: Int { bass ?? root }

  // MARK: - Names

  private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
  private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

  /// A note's name, with sharps or flats.
  public static func noteName(_ pitchClass: Int, flats: Bool = false) -> String {
    (flats ? flatNames : sharpNames)[((pitchClass % 12) + 12) % 12]
  }

  /// The chord's name: roots on the black keys use flats except F♯ and C♯ (as most charts do).
  public var description: String {
    let flats = ![1, 6].contains(root)
    var name = Self.noteName(root, flats: flats) + quality.suffix
    if let bass { name += "/" + Self.noteName(bass, flats: flats) }
    return name
  }

  /// Reads a chord's name: a root (A–G, then ♯/#/♭/b), a quality ("m", "min", "-", "7",
  /// "maj7", "M7", "Δ", "m7", "dim", "°", "m7b5", "ø", "aug", "+", "sus2", "sus4", "sus",
  /// "6", "m6", "add9", "9", "m9", "5", or nothing for major) and an optional "/bass".
  public init?(name: String) {
    var text = name.trimmingCharacters(in: .whitespaces)
    var bass: Int?
    if let slash = text.lastIndex(of: "/") {
      guard let parsed = Self.parseNote(String(text[text.index(after: slash)...])), parsed.rest.isEmpty else { return nil }
      bass = parsed.pitchClass
      text = String(text[..<slash])
    }
    guard let note = Self.parseNote(text) else { return nil }
    let suffixes: [String: Quality] = [
      "": .major, "maj": .major, "M": .major, "m": .minor, "min": .minor, "-": .minor, "7": .dominant7,
      "maj7": .major7, "M7": .major7, "Δ": .major7, "Δ7": .major7, "ma7": .major7, "m7": .minor7, "min7": .minor7,
      "-7": .minor7, "dim": .diminished, "°": .diminished, "o": .diminished, "m7b5": .halfDiminished,
      "m7♭5": .halfDiminished, "ø": .halfDiminished, "ø7": .halfDiminished, "aug": .augmented, "+": .augmented,
      "sus2": .sus2, "sus4": .sus4, "sus": .sus4, "6": .six, "m6": .minor6, "add9": .add9, "9": .dominant9,
      "m9": .minor9, "5": .power,
    ]
    guard let quality = suffixes[note.rest] else { return nil }
    self.init(root: note.pitchClass, quality: quality, bass: bass)
  }

  private static func parseNote(_ text: String) -> (pitchClass: Int, rest: String)? {
    guard let first = text.first?.uppercased(), let letter = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][first]
    else { return nil }
    var rest = text.dropFirst()
    var pitchClass = letter
    if let accidental = rest.first, "#♯b♭".contains(accidental) {
      // "b" after the letter is a flat (no quality starts with b).
      pitchClass += accidental == "#" || accidental == "♯" ? 1 : -1
      rest = rest.dropFirst()
    }
    return ((pitchClass + 12) % 12, String(rest))
  }

  // MARK: - Detection

  /// The chords commonly heard, tried when working out a chord from notes.
  static let detectedQualities: [Quality] = [.major, .minor, .dominant7, .major7, .minor7, .diminished, .sus4]

  /// The chord that best fits some sounding notes, each weighted by how long and hard it
  /// sounds; nil if there are too few notes to tell.
  public static func detect(_ weights: [Int: Double], lowest: Int?) -> Chord? {
    let total = weights.values.reduce(0, +)
    guard total > 0, weights.count >= 2 else { return nil }
    var best: (chord: Chord, score: Double)?
    for root in 0..<12 {
      for quality in detectedQualities {
        let tones = Set(quality.intervals.map { (root + $0) % 12 })
        let inside = tones.reduce(0) { $0 + (weights[$1] ?? 0) }
        let outside = total - inside
        // Chord tones heard, minus notes outside it; a missing tone costs a little, a missing
        // root more; four-note chords must earn their seventh.
        var score = inside - 1.2 * outside
        for tone in tones where weights[tone] == nil { score -= total * (tone == root ? 0.35 : 0.12) }
        if tones.count > 3 { score -= total * 0.05 }
        if lowest == root { score += total * 0.15 }
        if score > (best?.score ?? -.infinity) { best = (Chord(root: root, quality: quality), score) }
      }
    }
    guard var chord = best?.chord else { return nil }
    // A chord tone in the bass that isn't the root makes it a slash chord.
    if let lowest, lowest != chord.root, chord.pitchClasses.contains(lowest) { chord.bass = lowest }
    return chord
  }
}

/// A chord on the Chord track, from its position until the next one.
public struct ChordChange: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var position: Tick
  public var chord: Chord

  public init(id: UUID = UUID(), position: Tick, chord: Chord) {
    self.id = id
    self.position = position
    self.chord = chord
  }
}

extension Project {
  /// The chord sounding at a position: the Chord track's, else the key's own chord.
  public func chord(at position: Tick) -> Chord {
    chordTimeline.chord(at: position)
  }

  /// The chords between two positions, each with where it starts and ends (clipped to the
  /// range); the key's chord where there's none.
  public func chordSpans(from start: Tick, to end: Tick) -> [(start: Tick, end: Tick, chord: Chord)] {
    guard end > start else { return [] }
    var spans: [(start: Tick, end: Tick, chord: Chord)] = []
    var position = start
    var current = chord(at: start)
    for change in chords where change.position > start && change.position < end {
      spans.append((position, change.position, current))
      position = change.position
      current = change.chord
    }
    spans.append((position, end, current))
    return spans.filter { $0.end > $0.start }
  }

  /// Works out the chords in a MIDI region's notes, every half bar (or every bar for a
  /// steady part), merging repeats. Positions are on the song's timeline.
  public func detectChords(in region: Region) -> [ChordChange] {
    guard case .midi = region.content else { return [] }
    let notes = region.playedNotes
    var changes: [ChordChange] = []
    var barIndex = tempoMap.bar(containing: region.start).index
    var windowStart = region.start
    while windowStart < region.end {
      let barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
      let barEnd = tempoMap.tickPosition(ofBarIndex: barIndex + 1)
      let half = barStart + Tick((barEnd - barStart).rawValue / 2)
      for (from, to) in [(max(barStart, region.start), half), (half, min(barEnd, region.end))] where to > from {
        var weights: [Int: Double] = [:]
        var lowest: (pitch: Int, weight: Double)?
        for note in notes {
          let noteStart = region.start + note.start, noteEnd = noteStart + note.length
          let overlap = min(noteEnd, to) - max(noteStart, from)
          guard overlap > .zero else { continue }
          let weight = Double(overlap.rawValue) * (0.5 + Double(note.velocity) / 254)
          weights[note.pitch % 12, default: 0] += weight
          if lowest == nil || note.pitch < lowest!.pitch { lowest = (note.pitch, weight) }
        }
        guard let chord = Chord.detect(weights, lowest: lowest.map { $0.pitch % 12 }) else { continue }
        if changes.last?.chord != chord {
          changes.append(ChordChange(position: from, chord: chord))
        }
      }
      barIndex += 1
      windowStart = barEnd
    }
    return changes
  }
}
