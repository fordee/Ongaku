//
//  MIDIEffects.swift
//  OngakuCore
//

import Foundation

/// A MIDI effect in an instrument track's MIDI FX slots, as in Logic: it changes the notes
/// before the instrument plays them. Played notes stay as recorded in their regions; the
/// effects are applied as the song plays (and bounces, and freezes), so they can be changed
/// or bypassed at any time.
public struct MIDIEffect: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var settings: Settings
  public var isBypassed: Bool

  public init(id: UUID = UUID(), _ settings: Settings, isBypassed: Bool = false) {
    self.id = id
    self.settings = settings
    self.isBypassed = isBypassed
  }

  /// The most MIDI FX slots a channel strip has (Logic has eight).
  public static let maximumCount = 8

  public enum Settings: Codable, Sendable, Equatable {
    case arpeggiator(Arpeggiator)
    case chordTrigger(ChordTrigger)
    case scaleQuantize(ScaleQuantize)
    case noteRepeater(NoteRepeater)
    case transposer(Transposer)
    case velocityProcessor(VelocityProcessor)
    case randomizer(Randomizer)

    /// What it's called in the MIDI FX menu.
    public var name: String {
      switch self {
      case .arpeggiator: "Arpeggiator"
      case .chordTrigger: "Chord Trigger"
      case .scaleQuantize: "Scale Quantize"
      case .noteRepeater: "Note Repeater"
      case .transposer: "Transposer"
      case .velocityProcessor: "Velocity Processor"
      case .randomizer: "Randomizer"
      }
    }

    /// Each effect, with its default settings, for the MIDI FX menu.
    public static let all: [Settings] = [
      .arpeggiator(Arpeggiator()), .chordTrigger(ChordTrigger()), .noteRepeater(NoteRepeater()),
      .randomizer(Randomizer()), .scaleQuantize(ScaleQuantize()), .transposer(Transposer()),
      .velocityProcessor(VelocityProcessor()),
    ]
  }

  public var name: String { settings.name }
}

/// A note as MIDI effects see it: when it plays and stops (on the song's timeline), and
/// what it is.
public struct EffectNote: Sendable, Equatable {
  public var start: Tick
  public var end: Tick
  public var pitch: Int
  public var velocity: Int
  public var channel: Int

  public init(start: Tick, end: Tick, pitch: Int, velocity: Int, channel: Int = 0) {
    self.start = start
    self.end = end
    self.pitch = pitch
    self.velocity = velocity
    self.channel = channel
  }

  var clamped: EffectNote {
    var note = self
    note.pitch = min(max(pitch, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound)
    note.velocity = min(max(velocity, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
    note.end = max(end, start + Tick(1))
    return note
  }
}

/// A note length for timed effects, as Logic's Rate menus list them.
public enum NoteDivision: String, Codable, Sendable, CaseIterable, Identifiable {
  case quarter, quarterTriplet, eighth, eighthTriplet, sixteenth, sixteenthTriplet, thirtySecond, thirtySecondTriplet

  public var id: Self { self }

  public var ticks: Tick {
    switch self {
    case .quarter: Tick(960)
    case .quarterTriplet: Tick(640)
    case .thirtySecondTriplet: Tick(80)
    case .eighth: Tick(480)
    case .eighthTriplet: Tick(320)
    case .sixteenth: Tick(240)
    case .sixteenthTriplet: Tick(160)
    case .thirtySecond: Tick(120)
    }
  }

  public var title: String {
    switch self {
    case .quarter: "1/4"
    case .quarterTriplet: "1/4T"
    case .thirtySecondTriplet: "1/32T"
    case .eighth: "1/8"
    case .eighthTriplet: "1/8T"
    case .sixteenth: "1/16"
    case .sixteenthTriplet: "1/16T"
    case .thirtySecond: "1/32"
    }
  }
}

// MARK: - The effects

/// Plays held chords as a pattern of single notes on the song's grid.
public struct Arpeggiator: Codable, Sendable, Equatable {
  public enum Order: String, Codable, Sendable, CaseIterable, Identifiable {
    case up, down, upDown, downUp, asPlayed, random, chord
    public var id: Self { self }
    public var title: String {
      switch self {
      case .up: "Up"
      case .down: "Down"
      case .upDown: "Up & Down"
      case .downUp: "Down & Up"
      case .asPlayed: "As Played"
      case .random: "Random"
      case .chord: "Chord"
      }
    }
  }

  public var rate: NoteDivision
  public var order: Order
  /// How many octaves the pattern climbs through (1–4).
  public var octaves: Int
  /// How long each note plays, as a fraction of a step (0.05–1).
  public var gate: Double
  /// Every note at this velocity; nil plays each at the velocity it was played with.
  public var fixedVelocity: Int?

  public init(rate: NoteDivision = .sixteenth, order: Order = .up, octaves: Int = 1, gate: Double = 0.8, fixedVelocity: Int? = nil) {
    self.rate = rate
    self.order = order
    self.octaves = octaves
    self.gate = gate
    self.fixedVelocity = fixedVelocity
  }
}

/// Plays a chord from each note.
public struct ChordTrigger: Codable, Sendable, Equatable {
  public enum Chord: String, Codable, Sendable, CaseIterable, Identifiable {
    case major, minor, seventh, majorSeventh, minorSeventh, sus4, add9, power, octaves
    public var id: Self { self }
    public var title: String {
      switch self {
      case .major: "Major"
      case .minor: "Minor"
      case .seventh: "Dominant 7th"
      case .majorSeventh: "Major 7th"
      case .minorSeventh: "Minor 7th"
      case .sus4: "Sus 4"
      case .add9: "Add 9"
      case .power: "Power (5th)"
      case .octaves: "Octaves"
      }
    }
    /// Semitones above the played note.
    public var intervals: [Int] {
      switch self {
      case .major: [0, 4, 7]
      case .minor: [0, 3, 7]
      case .seventh: [0, 4, 7, 10]
      case .majorSeventh: [0, 4, 7, 11]
      case .minorSeventh: [0, 3, 7, 10]
      case .sus4: [0, 5, 7]
      case .add9: [0, 4, 7, 14]
      case .power: [0, 7, 12]
      case .octaves: [0, 12]
      }
    }
  }

  public var chord: Chord

  public init(chord: Chord = .major) {
    self.chord = chord
  }
}

/// Moves every note to the nearest note of a scale.
public struct ScaleQuantize: Codable, Sendable, Equatable {
  public enum Scale: String, Codable, Sendable, CaseIterable, Identifiable {
    case major, naturalMinor, harmonicMinor, dorian, mixolydian, majorPentatonic, minorPentatonic, blues
    public var id: Self { self }
    public var title: String {
      switch self {
      case .major: "Major"
      case .naturalMinor: "Natural Minor"
      case .harmonicMinor: "Harmonic Minor"
      case .dorian: "Dorian"
      case .mixolydian: "Mixolydian"
      case .majorPentatonic: "Major Pentatonic"
      case .minorPentatonic: "Minor Pentatonic"
      case .blues: "Blues"
      }
    }
    /// The scale's notes, in semitones above the root.
    public var degrees: [Int] {
      switch self {
      case .major: [0, 2, 4, 5, 7, 9, 11]
      case .naturalMinor: [0, 2, 3, 5, 7, 8, 10]
      case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
      case .dorian: [0, 2, 3, 5, 7, 9, 10]
      case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
      case .majorPentatonic: [0, 2, 4, 7, 9]
      case .minorPentatonic: [0, 3, 5, 7, 10]
      case .blues: [0, 3, 5, 6, 7, 10]
      }
    }
  }

  /// The scale's root, 0 (C) to 11 (B).
  public var root: Int
  public var scale: Scale

  public init(root: Int = 0, scale: Scale = .major) {
    self.root = root
    self.scale = scale
  }

  /// The nearest pitch in the scale (the lower one when two are as near).
  public func quantize(_ pitch: Int) -> Int {
    let degrees = Set(scale.degrees)
    for distance in 0...6 {
      for candidate in [pitch - distance, pitch + distance] where degrees.contains(((candidate - root) % 12 + 12) % 12) {
        return candidate
      }
    }
    return pitch
  }
}

/// Repeats each note, like an echo on the notes themselves.
public struct NoteRepeater: Codable, Sendable, Equatable {
  public var rate: NoteDivision
  public var repeats: Int
  /// How much each repeat's velocity changes, in percent of the last (−100 to 100).
  public var velocityChange: Double
  /// How far each repeat is transposed from the last, in semitones.
  public var transpose: Int

  public init(rate: NoteDivision = .eighth, repeats: Int = 3, velocityChange: Double = -25, transpose: Int = 0) {
    self.rate = rate
    self.repeats = repeats
    self.velocityChange = velocityChange
    self.transpose = transpose
  }
}

public struct Transposer: Codable, Sendable, Equatable {
  public var semitones: Int

  public init(semitones: Int = 0) {
    self.semitones = semitones
  }
}

/// Scales, shifts, limits or fixes velocities.
public struct VelocityProcessor: Codable, Sendable, Equatable {
  /// The velocity is multiplied by this (in percent), then the offset is added.
  public var scale: Double
  public var offset: Int
  public var minimum: Int
  public var maximum: Int
  /// Every note at this velocity, if set.
  public var fixed: Int?

  public init(scale: Double = 100, offset: Int = 0, minimum: Int = 1, maximum: Int = 127, fixed: Int? = nil) {
    self.scale = scale
    self.offset = offset
    self.minimum = minimum
    self.maximum = maximum
    self.fixed = fixed
  }

  public func process(_ velocity: Int) -> Int {
    let value = fixed ?? Int((Double(velocity) * scale / 100).rounded()) + offset
    return min(max(value, max(1, minimum)), min(127, max(minimum, maximum)))
  }
}

/// Changes notes a little at random, so parts sound less mechanical. The same notes come
/// out the same way every time the song plays (and bounces), from the effect's own seed.
public struct Randomizer: Codable, Sendable, Equatable {
  /// Velocities move up to this much either way.
  public var velocity: Int
  /// Notes move up to this many ticks either way.
  public var timing: Int
  /// Pitches move up to this many semitones either way…
  public var pitch: Int
  /// …this often (0–100 %).
  public var pitchChance: Double
  public var seed: UInt64

  public init(velocity: Int = 15, timing: Int = 0, pitch: Int = 0, pitchChance: Double = 0, seed: UInt64 = 0x5EED) {
    self.velocity = velocity
    self.timing = timing
    self.pitch = pitch
    self.pitchChance = pitchChance
    self.seed = seed
  }
}

// MARK: - Processing

extension MIDIEffect.Settings {
  /// The effect's notes from these (sorted by start), on the song's timeline.
  public func process(_ notes: [EffectNote]) -> [EffectNote] {
    switch self {
    case .arpeggiator(let settings): settings.process(notes)
    case .chordTrigger(let settings):
      notes.flatMap { note in
        settings.chord.intervals.map { interval in
          var chordNote = note
          chordNote.pitch = note.pitch + interval
          return chordNote
        }
        .filter { MIDINote.pitchRange.contains($0.pitch) }
      }
    case .scaleQuantize(let settings):
      notes.map { note in
        var quantized = note
        quantized.pitch = settings.quantize(note.pitch)
        return quantized.clamped
      }
    case .noteRepeater(let settings):
      notes.flatMap { note in
        var played = [note]
        var velocity = Double(note.velocity)
        for index in 1...max(1, settings.repeats) where settings.repeats > 0 {
          velocity *= 1 + settings.velocityChange / 100
          guard velocity >= 1 else { break }
          var echo = note
          let offset = settings.rate.ticks * Int64(index)
          echo.start = note.start + offset
          echo.end = note.end + offset
          echo.pitch = note.pitch + settings.transpose * index
          echo.velocity = Int(velocity.rounded())
          guard MIDINote.pitchRange.contains(echo.pitch) else { break }
          played.append(echo.clamped)
        }
        return played
      }
    case .transposer(let settings):
      notes.compactMap { note in
        var moved = note
        moved.pitch = note.pitch + settings.semitones
        return MIDINote.pitchRange.contains(moved.pitch) ? moved : nil
      }
    case .velocityProcessor(let settings):
      notes.map { note in
        var processed = note
        processed.velocity = settings.process(note.velocity)
        return processed
      }
    case .randomizer(let settings): settings.process(notes)
    }
  }
}

extension [MIDIEffect] {
  /// The notes after every effect that isn't bypassed, in slot order, sorted by start.
  public func process(_ notes: [EffectNote]) -> [EffectNote] {
    var current = notes.sorted { $0.start < $1.start }
    for effect in self where !effect.isBypassed {
      current = effect.settings.process(current).sorted { $0.start < $1.start }
    }
    return current
  }
}

extension Arpeggiator {
  /// Steps through the grid while notes are held: each step plays the next note of the held
  /// chord in the pattern's order (through the octaves), starting again once every key has
  /// been let go. A note counts as held for a step if it starts by the middle of the step.
  func process(_ notes: [EffectNote]) -> [EffectNote] {
    guard let first = notes.map(\.start).min(), let last = notes.map(\.end).max() else { return [] }
    let step = rate.ticks
    let length = Tick(max(1, Int64((Double(step.rawValue) * min(max(gate, 0.05), 1)).rounded())))
    var output: [EffectNote] = []
    var position = 0
    var random = SplitMix(seed: 0xA4E9)
    var time = Tick(first.rawValue / step.rawValue * step.rawValue)
    var startIndex = 0
    var active: [EffectNote] = []
    while time < last {
      let middle = time + Tick(step.rawValue / 2)
      while startIndex < notes.count, notes[startIndex].start <= middle {
        active.append(notes[startIndex])
        startIndex += 1
      }
      active.removeAll { $0.end <= time }
      guard !active.isEmpty else {
        position = 0
        // Jump to the next note's step rather than walking through the silence.
        guard startIndex < notes.count else { break }
        let next = notes[startIndex].start
        time = max(time + step, Tick(next.rawValue / step.rawValue * step.rawValue))
        continue
      }
      let held = active
      let pattern = sequence(held, random: &random)
      if order == .chord {
        for note in held {
          output.append(arpeggiated(note.pitch, from: note, at: time, length: length))
        }
      } else if !pattern.isEmpty {
        let pitch = pattern[position % pattern.count]
        // The held note it came from (an octave up is still that note), for its velocity.
        let source = held.first { ($0.pitch - pitch) % 12 == 0 } ?? held[0]
        output.append(arpeggiated(pitch, from: source, at: time, length: length))
      }
      position += 1
      time += step
    }
    return output
  }

  private func arpeggiated(_ pitch: Int, from source: EffectNote, at time: Tick, length: Tick) -> EffectNote {
    EffectNote(start: time, end: time + length, pitch: pitch, velocity: fixedVelocity ?? source.velocity, channel: source.channel)
      .clamped
  }

  /// The pitches the pattern goes through, over the octaves.
  private func sequence(_ held: [EffectNote], random: inout SplitMix) -> [Int] {
    let octaves = Swift.max(1, Swift.min(4, self.octaves))
    let byPitch = Array(Set(held.map(\.pitch))).sorted()
    let played = held.map(\.pitch)
    let ascending = (0..<octaves).flatMap { octave in byPitch.map { $0 + 12 * octave } }.filter { $0 <= 127 }
    switch order {
    case .up: return ascending
    case .down: return ascending.reversed()
    case .upDown: return ascending.count > 2 ? ascending + ascending.reversed().dropFirst().dropLast() : ascending
    case .downUp:
      let descending = Array(ascending.reversed())
      return descending.count > 2 ? descending + descending.reversed().dropFirst().dropLast() : descending
    case .asPlayed: return (0..<octaves).flatMap { octave in played.map { $0 + 12 * octave } }.filter { $0 <= 127 }
    case .random: return ascending.isEmpty ? [] : [ascending[Int(random.next() % UInt64(ascending.count))]]
    case .chord: return byPitch
    }
  }
}

extension Randomizer {
  /// Each note's changes come from its own seed (from the effect's, the note's start and its
  /// pitch), so a note comes out the same whatever else is playing: live, the same note is
  /// worked out again and again as it's held.
  func process(_ notes: [EffectNote]) -> [EffectNote] {
    notes.map { note in
      var random = SplitMix(seed: seed ^ (UInt64(bitPattern: note.start.rawValue) &* 0x9E37_79B9_7F4A_7C15) ^ UInt64(note.pitch &* 131 &+ note.channel))
      var changed = note
      let roll = { (amount: Int) -> Int in
        amount > 0 ? Int(((random.unit() * 2 - 1) * Double(amount)).rounded()) : 0
      }
      changed.velocity = note.velocity + roll(velocity)
      let shift = Tick(Int64(roll(timing)))
      changed.start = Swift.max(.zero, note.start + shift)
      changed.end = changed.start + (note.end - note.start)
      if pitch > 0, random.unit() * 100 < pitchChance {
        changed.pitch = note.pitch + roll(pitch)
      }
      return changed.clamped
    }
  }
}
