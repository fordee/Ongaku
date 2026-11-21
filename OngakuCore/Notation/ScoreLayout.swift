//
//  ScoreLayout.swift
//  OngakuCore
//

import Foundation

/// A MIDI region written out as music notation, the way Logic's Score editor shows it: its
/// notes quantized for display, cut into bars and beats as notes, rests and ties, spelled
/// for the key, on one staff, a grand staff or a drum staff. The view draws it; MusicXML
/// export writes it. The notes themselves are never changed.
public struct ScoreLayout: Sendable {
  public var staves: [ScoreStaff]
  public var measures: [ScoreMeasure]

  public init(staves: [ScoreStaff], measures: [ScoreMeasure]) {
    self.staves = staves
    self.measures = measures
  }
}

/// One staff of a score.
public struct ScoreStaff: Hashable, Sendable {
  public var clef: Clef

  public init(clef: Clef) {
    self.clef = clef
  }
}

public enum Clef: String, Codable, Sendable, CaseIterable {
  case treble, bass, percussion

  /// The diatonic step (see `ScoreNote.diatonic`) of the staff's middle line.
  public var middleLine: Int {
    switch self {
    case .treble: ScoreNote.diatonic(step: 6, octave: 4)  // B4
    case .bass: ScoreNote.diatonic(step: 1, octave: 3)  // D3
    case .percussion: ScoreNote.diatonic(step: 6, octave: 4)
    }
  }
}

/// Which staff or staves a part is written on.
public enum ClefChoice: String, Codable, Sendable, CaseIterable {
  /// Treble, bass or both, from the notes' range.
  case automatic
  case treble, bass
  /// A treble and bass staff split at a note.
  case grand
  case percussion

  public var title: String {
    switch self {
    case .automatic: "Automatic"
    case .treble: "Treble"
    case .bass: "Bass"
    case .grand: "Piano (Grand Staff)"
    case .percussion: "Drums"
    }
  }
}

/// How a score is laid out.
public struct ScoreOptions: Hashable, Sendable {
  /// The finest note value shown: notes are moved to it for display (Logic's display quantize).
  public var quantize: Tick
  /// Whether beats played in thirds are written as triplets.
  public var allowsTriplets: Bool
  public var clef: ClefChoice
  /// On a grand staff, the lowest note on the treble staff (middle C).
  public var splitPoint: Int
  public var showsChordSymbols: Bool

  public init(
    quantize: Tick = Tick(Tick.perQuarterNote / 4), allowsTriplets: Bool = true, clef: ClefChoice = .automatic,
    splitPoint: Int = 60, showsChordSymbols: Bool = true
  ) {
    self.quantize = quantize
    self.allowsTriplets = allowsTriplets
    self.clef = clef
    self.splitPoint = splitPoint
    self.showsChordSymbols = showsChordSymbols
  }

  /// The display quantize values offered, as Logic offers them.
  public static let quantizeValues: [(title: String, ticks: Tick)] = [
    ("1/4", Tick(Tick.perQuarterNote)), ("1/8", Tick(Tick.perQuarterNote / 2)), ("1/16", Tick(Tick.perQuarterNote / 4)),
    ("1/32", Tick(Tick.perQuarterNote / 8)),
  ]
}

/// One bar of a score.
public struct ScoreMeasure: Sendable, Identifiable {
  /// The bar's 0-based index in the song.
  public var index: Int
  public var id: Int { index }
  public var start: Tick
  public var length: Tick
  public var signature: TimeSignature
  public var key: KeySignature
  /// Whether the bar shows its time signature (the first bar, and where it changes).
  public var showsSignature: Bool
  /// Whether the bar shows its key signature (the first bar, and where it changes).
  public var showsKey: Bool
  /// Each staff's notes and rests, in order (one array per `ScoreLayout.staves` entry).
  public var events: [[ScoreEvent]]
  /// Chord symbols, by where they start.
  public var chordSymbols: [ChordSymbol]

  public var end: Tick { start + length }
}

public struct ChordSymbol: Hashable, Sendable {
  public var position: Tick
  public var chord: Chord

  public var name: String { chord.description }
}

/// A note value as it's written: its shape and dots, possibly in a tuplet.
public struct NoteValue: Hashable, Sendable {
  public enum Base: Int, CaseIterable, Sendable {
    case whole = 1, half = 2, quarter = 4, eighth = 8, sixteenth = 16, thirtySecond = 32

    public var ticks: Int64 { Tick.perQuarterNote * 4 / Int64(rawValue) }
    /// Flags (or beams) on its stem.
    public var flags: Int {
      switch self {
      case .whole, .half, .quarter: 0
      case .eighth: 1
      case .sixteenth: 2
      case .thirtySecond: 3
      }
    }
    /// The MusicXML name.
    public var name: String {
      switch self {
      case .whole: "whole"
      case .half: "half"
      case .quarter: "quarter"
      case .eighth: "eighth"
      case .sixteenth: "16th"
      case .thirtySecond: "32nd"
      }
    }
  }

  public var base: Base
  public var dots: Int
  /// Three in the time of two.
  public var isTriplet: Bool

  public init(base: Base, dots: Int = 0, isTriplet: Bool = false) {
    self.base = base
    self.dots = dots
    self.isTriplet = isTriplet
  }

  /// How long it lasts.
  public var ticks: Int64 {
    var total = base.ticks
    var add = base.ticks
    for _ in 0..<dots {
      add /= 2
      total += add
    }
    return isTriplet ? total * 2 / 3 : total
  }
}

/// A note or chord (or a rest, with no notes) on a staff.
public struct ScoreEvent: Sendable, Identifiable {
  public var id: Int
  public var start: Tick
  public var value: NoteValue
  /// Empty for a rest.
  public var notes: [ScoreNote]
  /// Notes and chords beamed together share a group number.
  public var beamGroup: Int?
  /// Triplets in the same beat share a group number, for the bracket.
  public var tupletGroup: Int?

  public var isRest: Bool { notes.isEmpty }
  public var length: Tick { Tick(value.ticks) }
  public var end: Tick { start + length }
}

/// One note head.
public struct ScoreNote: Hashable, Sendable {
  /// The MIDI note it plays (and which `MIDINote` it is, for editing).
  public var noteID: UUID
  public var pitch: Int
  /// Its letter, C = 0 … B = 6.
  public var step: Int
  /// −1 flat, 0 natural, 1 sharp.
  public var alter: Int
  /// The scientific octave (middle C is in octave 4).
  public var octave: Int
  /// The accidental to print, if the key and the bar so far don't already give it.
  public var accidental: Accidental?
  /// Tied on to the same note in the next event.
  public var tiesToNext: Bool
  /// Continues a tie from the previous event.
  public var isTiedFromPrevious: Bool
  /// On a drum staff, a cymbal's cross instead of a round head.
  public var isCross: Bool

  /// Steps up from C0: one per line or space.
  public var diatonic: Int { Self.diatonic(step: step, octave: octave) }

  public static func diatonic(step: Int, octave: Int) -> Int { octave * 7 + step }
}

public enum Accidental: String, Sendable {
  case sharp, flat, natural

  public var symbol: String {
    switch self {
    case .sharp: "♯"
    case .flat: "♭"
    case .natural: "♮"
    }
  }
}

// MARK: - Laying out

extension ScoreLayout {
  /// The score of a MIDI region in its song.
  public init(region: Region, in project: Project, isDrumPart: Bool = false, options: ScoreOptions = ScoreOptions()) {
    let notes = region.playedNotes.filter { !$0.isMuted }.map { note -> MIDINote in
      var note = note
      note.start = note.start + region.start
      return note
    }.filter { $0.start < region.end }
    let tempoMap = project.tempoMap
    // The bars the region covers.
    let first = tempoMap.bar(containing: region.start)
    let last = tempoMap.bar(containing: max(region.start, region.end - Tick(1)))
    let bars: [(index: Int, start: Tick, signature: TimeSignature)] = (first.index...last.index).map { index in
      (index, tempoMap.tickPosition(ofBarIndex: index), tempoMap.timeSignature(atBarIndex: index))
    }
    let barEnd = bars.last.map { $0.start + $0.signature.ticksPerBar } ?? region.end

    // Which staves, and which notes go on each.
    let choice: ClefChoice = isDrumPart ? .percussion : options.clef
    var staffNotes: [[MIDINote]]
    var staves: [ScoreStaff]
    switch choice {
    case .percussion:
      staves = [ScoreStaff(clef: .percussion)]
      staffNotes = [notes]
    case .treble:
      staves = [ScoreStaff(clef: .treble)]
      staffNotes = [notes]
    case .bass:
      staves = [ScoreStaff(clef: .bass)]
      staffNotes = [notes]
    case .grand:
      staves = [ScoreStaff(clef: .treble), ScoreStaff(clef: .bass)]
      staffNotes = [notes.filter { $0.pitch >= options.splitPoint }, notes.filter { $0.pitch < options.splitPoint }]
    case .automatic:
      let low = notes.map(\.pitch).min() ?? 60, high = notes.map(\.pitch).max() ?? 60
      if low >= options.splitPoint - 5 || notes.isEmpty {
        staves = [ScoreStaff(clef: .treble)]
        staffNotes = [notes]
      } else if high < options.splitPoint + 5 {
        staves = [ScoreStaff(clef: .bass)]
        staffNotes = [notes]
      } else {
        staves = [ScoreStaff(clef: .treble), ScoreStaff(clef: .bass)]
        staffNotes = [notes.filter { $0.pitch >= options.splitPoint }, notes.filter { $0.pitch < options.splitPoint }]
      }
    }

    var builder = Builder(options: options, isDrums: choice == .percussion)
    let staffEvents = staffNotes.map { builder.events(for: $0, bars: bars, end: barEnd, project: project) }

    var previousSignature: TimeSignature?
    var previousKey: KeySignature?
    measures = bars.enumerated().map { barNumber, bar in
      let key = project.key(at: bar.start)
      let chords: [ChordSymbol] = options.showsChordSymbols && !project.chords.isEmpty
        ? project.chords.filter { $0.position >= bar.start && $0.position < bar.start + bar.signature.ticksPerBar }
          .map { ChordSymbol(position: $0.position, chord: $0.chord) }
        : []
      let measure = ScoreMeasure(
        index: bar.index, start: bar.start, length: bar.signature.ticksPerBar, signature: bar.signature, key: key,
        showsSignature: bar.signature != previousSignature, showsKey: key != previousKey,
        events: staffEvents.map { $0[barNumber] }, chordSymbols: chords)
      previousSignature = bar.signature
      previousKey = key
      return measure
    }
    self.staves = staves
  }
}

/// Builds each staff's events, bar by bar.
private struct Builder {
  let options: ScoreOptions
  let isDrums: Bool
  var nextID = 0
  var nextBeam = 0
  var nextTuplet = 0

  init(options: ScoreOptions, isDrums: Bool) {
    self.options = options
    self.isDrums = isDrums
  }

  /// A stretch of the timeline: a chord of notes (or silence) from `start` to `end`.
  struct Segment {
    var start: Int64
    var end: Int64
    var notes: [MIDINote]
    var isTriplet: Bool
    /// The same notes go on before and after this piece (it was cut at a bar or beat), so
    /// they're tied across.
    var continuesBefore = false
    var continuesAfter = false
  }

  /// The staff's events for each bar.
  mutating func events(
    for notes: [MIDINote], bars: [(index: Int, start: Tick, signature: TimeSignature)], end: Tick, project: Project
  ) -> [[ScoreEvent]] {
    let grid = max(Int64(30), options.quantize.rawValue)
    let segments = segments(of: notes, bars: bars, grid: grid, end: end.rawValue)
    return bars.map { bar in
      let barStart = bar.start.rawValue, barEnd = barStart + bar.signature.ticksPerBar.rawValue
      let inBar = segments.compactMap { segment -> Segment? in
        let start = max(segment.start, barStart), stop = min(segment.end, barEnd)
        guard stop > start else { return nil }
        var piece = segment
        piece.start = start
        piece.end = stop
        piece.continuesBefore = segment.continuesBefore || start > segment.start
        piece.continuesAfter = segment.continuesAfter || stop < segment.end
        return piece
      }
      var events = notate(inBar, barStart: barStart, signature: bar.signature, key: project.key(at: bar.start))
      beam(&events, barStart: barStart, signature: bar.signature)
      return events
    }
  }

  // MARK: Timeline

  /// The notes as one voice of chords and rests, quantized for display, covering every bar.
  func segments(
    of notes: [MIDINote], bars: [(index: Int, start: Tick, signature: TimeSignature)], grid: Int64, end: Int64
  ) -> [Segment] {
    guard let firstBar = bars.first else { return [] }
    let start = firstBar.start.rawValue
    // Which beats are played in thirds: a beat with a note that's nearer a third of the beat
    // than the straight grid.
    var tripletBeats = Set<Int64>()
    func signature(at position: Int64) -> TimeSignature {
      (bars.last { $0.start.rawValue <= position } ?? firstBar).signature
    }
    func beat(of position: Int64) -> (start: Int64, length: Int64) {
      let bar = bars.last { $0.start.rawValue <= position } ?? firstBar
      let length = bar.signature.isCompound ? bar.signature.pulse.rawValue : bar.signature.ticksPerBeat.rawValue
      let offset = position - bar.start.rawValue
      return (bar.start.rawValue + offset / length * length, length)
    }
    // Compound meters already divide their beats in three.
    if options.allowsTriplets {
      for note in notes {
        let (beatStart, beatLength) = beat(of: note.start.rawValue)
        guard beatLength % 3 == 0, !signature(at: beatStart).isCompound else { continue }
        let offset = note.start.rawValue - beatStart
        let straight = abs(offset - (offset + grid / 2) / grid * grid)
        let third = beatLength / 3
        let tripletError = abs(offset - (offset + third / 2) / third * third)
        if tripletError + 15 < straight, (offset + third / 2) / third % 3 != 0 { tripletBeats.insert(beatStart) }
      }
    }
    // Quantize each note's start and end.
    func quantize(_ position: Int64) -> Int64 {
      let (beatStart, beatLength) = beat(of: position)
      let step = tripletBeats.contains(beatStart) ? beatLength / 3 : grid
      let offset = position - beatStart
      return beatStart + (offset + step / 2) / step * step
    }
    var onsets: [Int64: [MIDINote]] = [:]
    var ends: [Int64: Int64] = [:]
    for note in notes {
      let noteStart = quantize(note.start.rawValue)
      guard noteStart < end else { continue }
      let minimum = tripletBeats.contains(beat(of: noteStart).start) ? beat(of: noteStart).length / 3 : grid
      let noteEnd = max(noteStart + minimum, quantize(note.start.rawValue + note.length.rawValue))
      onsets[noteStart, default: []].append(note)
      ends[noteStart] = max(ends[noteStart] ?? 0, noteEnd)
    }
    // One voice: each chord lasts until its longest note ends or the next chord starts.
    let times = onsets.keys.sorted()
    var segments: [Segment] = []
    var position = start
    for (index, time) in times.enumerated() {
      if time > position { segments.append(Segment(start: position, end: time, notes: [], isTriplet: false)) }
      let next = index + 1 < times.count ? times[index + 1] : end
      let stop = min(ends[time] ?? time, next, end)
      let chord = onsets[time]!.sorted { $0.pitch < $1.pitch }
      // Keep one of each pitch.
      var seen = Set<Int>()
      segments.append(Segment(start: time, end: stop, notes: chord.filter { seen.insert($0.pitch).inserted }, isTriplet: false))
      position = stop
    }
    if position < end { segments.append(Segment(start: position, end: end, notes: [], isTriplet: false)) }
    // Mark the pieces in triplet beats (cutting segments at their beats' edges).
    var result: [Segment] = []
    for segment in segments {
      var cursor = segment.start
      while cursor < segment.end {
        let (beatStart, beatLength) = beat(of: cursor)
        let isTriplet = tripletBeats.contains(beatStart)
        // A straight stretch runs on to the next triplet beat; a triplet one to its beat's end.
        var stop = segment.end
        if isTriplet {
          stop = min(stop, beatStart + beatLength)
        } else {
          var probe = beatStart + beatLength
          while probe < stop {
            if tripletBeats.contains(probe) {
              stop = probe
              break
            }
            probe += beat(of: probe).length
          }
        }
        var piece = segment
        piece.start = cursor
        piece.end = stop
        piece.isTriplet = isTriplet
        piece.continuesBefore = cursor > segment.start
        piece.continuesAfter = stop < segment.end
        result.append(piece)
        cursor = stop
      }
    }
    return result
  }

  // MARK: Note values

  /// A bar's segments written as notes and rests: each cut into values that fit where they
  /// start (tied when a note needs more than one), spelled with accidentals for the key.
  mutating func notate(_ segments: [Segment], barStart: Int64, signature: TimeSignature, key: KeySignature) -> [ScoreEvent] {
    // A bar of silence is a whole rest, whatever the meter.
    if segments.allSatisfy({ $0.notes.isEmpty }) {
      defer { nextID += 1 }
      return [ScoreEvent(id: nextID, start: Tick(barStart), value: NoteValue(base: .whole), notes: [])]
    }
    var spelling = Spelling(key: key)
    var events: [ScoreEvent] = []
    for segment in segments {
      let values: [(start: Int64, value: NoteValue)] = segment.isTriplet
        ? tripletValues(from: segment.start, to: segment.end)
        : straightValues(from: segment.start, to: segment.end, barStart: barStart, signature: signature, isRest: segment.notes.isEmpty)
      let tuplet: Int? = segment.isTriplet ? tupletGroup(for: segment.start, signature: signature, barStart: barStart) : nil
      for (index, piece) in values.enumerated() {
        let notes = segment.notes.map { note in
          spelling.note(
            note, tiesToNext: index < values.count - 1 || segment.continuesAfter,
            isTiedFromPrevious: index > 0 || segment.continuesBefore, isDrums: isDrums)
        }
        events.append(ScoreEvent(id: nextID, start: Tick(piece.start), value: piece.value, notes: notes, tupletGroup: tuplet))
        nextID += 1
      }
    }
    return events
  }

  private var tupletBeatGroups: [Int64: Int] = [:]

  /// One bracket per triplet beat.
  mutating func tupletGroup(for position: Int64, signature: TimeSignature, barStart: Int64) -> Int {
    let beat = signature.ticksPerBeat.rawValue
    let beatStart = barStart + (position - barStart) / beat * beat
    if let group = tupletBeatGroups[beatStart] { return group }
    nextTuplet += 1
    tupletBeatGroups[beatStart] = nextTuplet
    return nextTuplet
  }

  /// The values written for a straight stretch: at each point the longest value that fits,
  /// starts where that value may start, and doesn't hide the beat.
  func straightValues(from start: Int64, to end: Int64, barStart: Int64, signature: TimeSignature, isRest: Bool)
    -> [(start: Int64, value: NoteValue)]
  {
    let pulse = signature.pulse.rawValue
    let candidates: [NoteValue] = NoteValue.Base.allCases.flatMap { base in
      // Rests aren't dotted in simple meters (beyond a beat); notes may be.
      let dots = isRest && !signature.isCompound ? [0] : [1, 0]
      return dots.map { NoteValue(base: base, dots: $0) }
    }.sorted { $0.ticks > $1.ticks }
    var result: [(Int64, NoteValue)] = []
    var position = start
    while position < end {
      let offset = position - barStart
      let remaining = end - position
      let fit = candidates.first { value in
        let length = value.ticks
        guard length <= remaining, length <= signature.ticksPerBar.rawValue else { return false }
        if length > pulse {
          // Longer than a beat: start on a beat, and on a multiple of its own (undotted) length
          // in simple meters (no half note from beat 2 of 4/4).
          guard offset % pulse == 0 else { return false }
          if !signature.isCompound, value.dots == 0, offset % length != 0 { return false }
          // Don't hide the middle of an even bar (beat 3 of 4/4) unless starting the bar.
          let half = signature.ticksPerBar.rawValue / 2
          if !signature.isCompound, signature.beatsPerBar % 2 == 0, signature.beatsPerBar >= 4, offset != 0,
            offset < half, offset + length > half
          {
            return false
          }
          if signature.isCompound, length % pulse != 0 { return false }
          return true
        }
        // A beat or shorter: don't cross into the next beat, and start on the value's grid.
        let toNextBeat = pulse - offset % pulse
        guard length <= toNextBeat else { return false }
        let grain = value.dots > 0 ? value.base.ticks / 2 : value.base.ticks
        return offset % grain == 0 || (signature.isCompound && value.ticks == pulse)
      } ?? NoteValue(base: .thirtySecond)
      result.append((position, fit))
      position += max(fit.ticks, 1)
    }
    return result
  }

  /// The values written for a stretch of a triplet beat, in thirds (or sixths) of the beat.
  func tripletValues(from start: Int64, to end: Int64) -> [(start: Int64, value: NoteValue)] {
    let options: [NoteValue] = [.quarter, .eighth, .sixteenth, .thirtySecond].map { NoteValue(base: $0, isTriplet: true) }
    var result: [(Int64, NoteValue)] = []
    var position = start
    while position < end {
      let remaining = end - position
      let value = options.first { $0.ticks <= remaining } ?? NoteValue(base: .thirtySecond, isTriplet: true)
      result.append((position, value))
      position += max(value.ticks, 1)
    }
    return result
  }

  // MARK: Beams

  /// Beams eighths and shorter within each beat (each pulse in compound meters).
  mutating func beam(_ events: inout [ScoreEvent], barStart: Int64, signature: TimeSignature) {
    let unit = signature.isCompound ? signature.pulse.rawValue : signature.ticksPerBeat.rawValue
    var index = 0
    while index < events.count {
      guard !events[index].isRest, events[index].value.base.flags > 0 else {
        index += 1
        continue
      }
      let beat = (events[index].start.rawValue - barStart) / unit
      var last = index
      while last + 1 < events.count, !events[last + 1].isRest, events[last + 1].value.base.flags > 0,
        (events[last + 1].start.rawValue - barStart) / unit == beat
      {
        last += 1
      }
      if last > index {
        nextBeam += 1
        for member in index...last { events[member].beamGroup = nextBeam }
      }
      index = last + 1
    }
  }
}

// MARK: - Spelling

/// Spells notes for a key and keeps track of the accidentals already written in a bar.
struct Spelling {
  let key: KeySignature
  /// The alteration each letter has from the key signature.
  let keyAlterations: [Int]
  /// What's in force so far this bar, by letter and octave.
  var inForce: [Int: Int] = [:]

  init(key: KeySignature) {
    self.key = key
    let count = key.sharpsOrFlats
    var alterations = [Int](repeating: 0, count: 7)
    if count > 0 {
      for step in [3, 0, 4, 1, 5, 2, 6].prefix(count) { alterations[step] = 1 }  // F C G D A E B
    } else if count < 0 {
      for step in [6, 2, 5, 1, 4, 0, 3].prefix(-count) { alterations[step] = -1 }  // B E A D G C F
    }
    keyAlterations = alterations
  }

  /// The letter and alteration for a pitch in this key: the key's own notes as the key spells
  /// them, others with sharps in sharp keys and flats in flat keys.
  func spell(_ pitch: Int) -> (step: Int, alter: Int, octave: Int) {
    let pitchClass = ((pitch % 12) + 12) % 12
    let naturals = [0, 2, 4, 5, 7, 9, 11]
    // A letter whose key alteration gives this pitch class.
    for step in 0..<7 where (naturals[step] + keyAlterations[step] + 12) % 12 == pitchClass {
      return (step, keyAlterations[step], Self.octave(pitch, step: step, alter: keyAlterations[step]))
    }
    if let step = naturals.firstIndex(of: pitchClass) { return (step, 0, Self.octave(pitch, step: step, alter: 0)) }
    let useFlats = key.sharpsOrFlats < 0
    let step = useFlats ? naturals.firstIndex(of: pitchClass + 1)! : naturals.firstIndex(of: pitchClass - 1)!
    let alter = useFlats ? -1 : 1
    return (step, alter, Self.octave(pitch, step: step, alter: alter))
  }

  /// The scientific octave, from the letter (so B♯ and C♭ land in the right octave).
  static func octave(_ pitch: Int, step: Int, alter: Int) -> Int {
    let naturals = [0, 2, 4, 5, 7, 9, 11]
    return (pitch - alter - naturals[step]) / 12 - 1
  }

  mutating func note(_ note: MIDINote, tiesToNext: Bool, isTiedFromPrevious: Bool, isDrums: Bool) -> ScoreNote {
    if isDrums {
      let place = DrumNotation.place(note.pitch)
      return ScoreNote(
        noteID: note.id, pitch: note.pitch, step: place.step, alter: 0, octave: place.octave, accidental: nil,
        tiesToNext: tiesToNext, isTiedFromPrevious: isTiedFromPrevious, isCross: place.isCross)
    }
    let (step, alter, octave) = spell(note.pitch)
    let slot = octave * 7 + step
    let current = inForce[slot] ?? keyAlterations[step]
    var accidental: Accidental?
    if !isTiedFromPrevious && current != alter {
      accidental = alter == 1 ? .sharp : alter == -1 ? .flat : .natural
      inForce[slot] = alter
    }
    return ScoreNote(
      noteID: note.id, pitch: note.pitch, step: step, alter: alter, octave: octave, accidental: accidental,
      tiesToNext: tiesToNext, isTiedFromPrevious: isTiedFromPrevious, isCross: false)
  }
}

/// Where General MIDI drums sit on a drum staff, as most drum charts put them.
public enum DrumNotation {
  public static func place(_ pitch: Int) -> (step: Int, octave: Int, isCross: Bool) {
    switch pitch {
    case 35, 36: (3, 4, false)  // kick: F4
    case 37, 38, 39, 40: (0, 5, false)  // snare: C5
    case 41, 43: (4, 4, false)  // floor toms: G4 / A4
    case 45, 47: (1, 5, false)  // mid tom: D5
    case 48, 50: (2, 5, false)  // high tom: E5
    case 42, 46: (4, 5, true)  // hi-hat: G5
    case 44: (1, 4, true)  // pedal hat: D4
    case 49, 52, 55, 57: (5, 5, true)  // crash: A5
    case 51, 53, 59: (3, 5, true)  // ride: F5
    default: (0, 5, false)
    }
  }
}
