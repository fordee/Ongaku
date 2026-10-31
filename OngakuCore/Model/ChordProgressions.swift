//
//  ChordProgressions.swift
//  OngakuCore
//

import Foundation

/// A chord progression written in Roman numerals, so it plays in any key: "I V vi IV" is
/// C G Am F in C, and G D Em C in G. Each numeral is a bar.
public struct ChordProgression: Identifiable, Sendable, Hashable {
  public var name: String
  public var numerals: [String]
  public var mode: KeySignature.Mode

  public var id: String { "\(mode.rawValue) \(name)" }

  public init(_ name: String, _ numerals: String, mode: KeySignature.Mode = .major) {
    self.name = name
    self.numerals = numerals.split(separator: " ").map(String.init)
    self.mode = mode
  }

  /// "I–V–vi–IV".
  public var romanName: String { numerals.joined(separator: "–") }

  /// The progression's chords in a key.
  public func chords(in key: KeySignature) -> [Chord] {
    numerals.compactMap { Self.chord(numeral: $0, in: key) }
  }

  /// A Roman numeral's chord in a key. Numerals count the major scale's degrees from the
  /// key's tonic (♭ and ♯ move them); upper case is a major chord and lower case minor; "°"
  /// is diminished, "ø7" half-diminished, "+" augmented, "7" a dominant (or, in lower case,
  /// minor) seventh, and "maj7", "sus4", "sus2", "6", "9" and "add9" as in chord names.
  public static func chord(numeral: String, in key: KeySignature) -> Chord? {
    var text = Substring(numeral)
    var shift = 0
    if let first = text.first, "♭b♯#".contains(first) {
      shift = first == "♭" || first == "b" ? -1 : 1
      text = text.dropFirst()
    }
    let letters = text.prefix { "IViv".contains($0) }
    let degrees = ["I": 0, "II": 2, "III": 4, "IV": 5, "V": 7, "VI": 9, "VII": 11]
    guard !letters.isEmpty, let degree = degrees[letters.uppercased()] else { return nil }
    let isMinor = letters.first?.isLowercase == true
    let suffix = String(text.dropFirst(letters.count))
    let quality: Chord.Quality
    switch suffix {
    case "": quality = isMinor ? .minor : .major
    case "°": quality = .diminished
    case "ø7", "ø": quality = .halfDiminished
    case "+": quality = .augmented
    case "7": quality = isMinor ? .minor7 : .dominant7
    case "maj7": quality = .major7
    case "sus4": quality = .sus4
    case "sus2": quality = .sus2
    case "6": quality = isMinor ? .minor6 : .six
    case "9": quality = isMinor ? .minor9 : .dominant9
    case "add9": quality = .add9
    default: return nil
    }
    return Chord(root: key.tonic + degree + shift, quality: quality)
  }

  // MARK: - The library

  public static let major: [ChordProgression] = [
    ChordProgression("Pop", "I V vi IV"),
    ChordProgression("Classic", "I IV V I"),
    ChordProgression("Fifties", "I vi IV V"),
    ChordProgression("Sensitive", "vi IV I V"),
    ChordProgression("Lift", "IV I V vi"),
    ChordProgression("Build", "ii IV V V"),
    ChordProgression("Folk", "I IV I V"),
    ChordProgression("Turnaround", "I vi ii V"),
    ChordProgression("Rock", "I ♭VII IV I"),
    ChordProgression("Jazz", "ii7 V7 Imaj7 Imaj7"),
    ChordProgression("Soul", "Imaj7 iii7 IVmaj7 V7"),
    ChordProgression("Canon", "I V vi iii IV I IV V"),
    ChordProgression("Blues", "I7 I7 I7 I7 IV7 IV7 I7 I7 V7 IV7 I7 V7"),
  ]

  public static let minor: [ChordProgression] = [
    ChordProgression("Epic", "i ♭VI ♭III ♭VII", mode: .minor),
    ChordProgression("Andalusian", "i ♭VII ♭VI V", mode: .minor),
    ChordProgression("Lift", "♭VI ♭VII i i", mode: .minor),
    ChordProgression("Build", "iv ♭VI ♭VII ♭VII", mode: .minor),
    ChordProgression("Classic", "i iv V7 i", mode: .minor),
    ChordProgression("Rock", "i ♭VII ♭VI ♭VII", mode: .minor),
    ChordProgression("Ballad", "i ♭III ♭VII iv", mode: .minor),
    ChordProgression("Jazz", "iiø7 V7 i7 i7", mode: .minor),
    ChordProgression("Blues", "i7 i7 i7 i7 iv7 iv7 i7 i7 ♭VI7 V7 i7 V7", mode: .minor),
  ]

  /// The progressions that suit a key.
  public static func library(for key: KeySignature) -> [ChordProgression] {
    key.mode == .major ? major : minor
  }

  public static func named(_ name: String, mode: KeySignature.Mode) -> ChordProgression? {
    (mode == .major ? major : minor).first { $0.name == name }
  }

  // MARK: - Songs

  /// A song's progressions: verse, pre-chorus, chorus and bridge.
  static let majorSongs = [
    ["Fifties", "Build", "Pop", "Sensitive"],
    ["Classic", "Build", "Lift", "Turnaround"],
    ["Pop", "Build", "Lift", "Sensitive"],
    ["Folk", "Build", "Rock", "Sensitive"],
  ]
  static let minorSongs = [
    ["Epic", "Build", "Lift", "Andalusian"],
    ["Andalusian", "Build", "Epic", "Classic"],
    ["Rock", "Build", "Epic", "Ballad"],
    ["Ballad", "Build", "Lift", "Andalusian"],
  ]

  /// The progression a song section plays: verses, choruses and bridges each have their own,
  /// the same throughout a song (`song` picks which songwriter's habits).
  public static func forSection(named name: String, key: KeySignature, song: Int) -> ChordProgression {
    let songs = key.mode == .major ? majorSongs : minorSongs
    let parts = songs[((song % songs.count) + songs.count) % songs.count]
    let part: Int = switch name.lowercased() {
    case "pre-chorus": 1
    case "chorus", "outro": 2
    case "bridge": 3
    default: 0
    }
    return named(parts[part], mode: key.mode) ?? library(for: key)[0]
  }

  /// The chords from `start` to `end`, one a bar from the bar `start` is in, repeating the
  /// progression; the last bar can come home to the key's chord.
  public func changes(in key: KeySignature, from start: Tick, to end: Tick, tempoMap: TempoMap, endsHome: Bool = false)
    -> [ChordChange]
  {
    let chords = chords(in: key)
    guard !chords.isEmpty, end > start else { return [] }
    var changes: [ChordChange] = []
    var barIndex = tempoMap.bar(containing: start).index
    var position = tempoMap.tickPosition(ofBarIndex: barIndex)
    var index = 0
    while position < end {
      changes.append(ChordChange(position: max(position, start), chord: chords[index % chords.count]))
      index += 1
      barIndex += 1
      position = tempoMap.tickPosition(ofBarIndex: barIndex)
    }
    if endsHome, let home = Self.chord(numeral: key.mode == .major ? "I" : "i", in: key) {
      changes[changes.count - 1].chord = home
    }
    // Repeats of the same chord are one change.
    return changes.enumerated().filter { $0.offset == 0 || changes[$0.offset - 1].chord != $0.element.chord }.map(\.element)
  }
}
