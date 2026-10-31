//
//  SessionPlayer.swift
//  OngakuCore
//

import Foundation

/// A session player's part for one region, as with Logic's Bass Player and Keyboard
/// Player: an instrument, a style, how busy and how loud to play, and how to move between
/// chords. The part follows the Chord track: the region's notes are generated from it (see
/// `Region.renderPlayer(in:)`) whenever the performance, the region or the chords change.
public struct PlayerPerformance: Codable, Sendable, Equatable {
  public enum Instrument: String, Codable, Sendable, CaseIterable, Identifiable {
    case bass, keys
    public var id: Self { self }
    public var title: String { self == .bass ? "Bass" : "Keys" }
  }

  public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
    case rootNotes, drivingEighths, walking, funkBass, motown
    case pad, blockChords, popPulse, balladArpeggio, funkStabs

    public var id: Self { self }

    public var instrument: Instrument {
      switch self {
      case .rootNotes, .drivingEighths, .walking, .funkBass, .motown: .bass
      case .pad, .blockChords, .popPulse, .balladArpeggio, .funkStabs: .keys
      }
    }

    public static func styles(for instrument: Instrument) -> [Style] {
      allCases.filter { $0.instrument == instrument }
    }

    public var title: String {
      switch self {
      case .rootNotes: "Root Notes"
      case .drivingEighths: "Driving Eighths"
      case .walking: "Walking"
      case .funkBass: "Funk"
      case .motown: "Motown"
      case .pad: "Pad"
      case .blockChords: "Block Chords"
      case .popPulse: "Pop Pulse"
      case .balladArpeggio: "Ballad Arpeggio"
      case .funkStabs: "Funk Stabs"
      }
    }

    public var summary: String {
      switch self {
      case .rootNotes: "Long roots with room to breathe, and a pickup into each phrase"
      case .drivingEighths: "Eighths that drive the song, with octave pops and walk-ups"
      case .walking: "A line through the chords a beat at a time, leaning into each one"
      case .funkBass: "The one, then syncopated sixteenths, octave pops and dead notes"
      case .motown: "Melodic sixths and chromatic climbs, pushing ahead of the beat"
      case .pad: "Held chords with ninths, re-voiced so the top line moves"
      case .blockChords: "Piano chords on the beat over octaves, pushing into changes"
      case .popPulse: "Driving eighths and 3-3-2 pushes over a left-hand root"
      case .balladArpeggio: "A rolling left hand under held and broken chords"
      case .funkStabs: "Syncopated ninth and minor-seventh stabs and chanks"
      }
    }

    public var defaultSwing: Double { self == .walking ? 0.6 : 0 }

    /// Styles that swing sixteenths rather than eighths.
    var swingsSixteenths: Bool { self == .funkBass || self == .funkStabs }
  }

  public var style: Style
  /// Simple (0) to busy (1).
  public var complexity: Double
  /// Soft (0) to loud (1).
  public var loudness: Double
  /// Delays the off-beats toward a triplet feel at 1.
  public var swing: Double
  /// Octaves up (1) or down (−1) from the instrument's usual range.
  public var register: Int
  /// Leads into what comes after the region with an approach note or pickup.
  public var leadsIntoNext: Bool
  /// Which take: a new seed plays the same settings differently.
  public var seed: UInt64

  public var instrument: Instrument { style.instrument }

  public static let registerRange = -1...1

  public init(
    style: Style, complexity: Double = 0.45, loudness: Double = 0.55, swing: Double? = nil, register: Int = 0,
    leadsIntoNext: Bool = true, seed: UInt64 = 1
  ) {
    self.style = style
    self.complexity = complexity
    self.loudness = loudness
    self.swing = swing ?? style.defaultSwing
    self.register = min(max(register, Self.registerRange.lowerBound), Self.registerRange.upperBound)
    self.leadsIntoNext = leadsIntoNext
    self.seed = seed
  }

  /// How a player plays a song section, from its name, as the Drummer does.
  public static func forSection(named name: String, style: Style, isLast: Bool, seed: UInt64) -> PlayerPerformance {
    var part = PlayerPerformance(style: style, seed: seed)
    switch name.lowercased() {
    case "intro": (part.complexity, part.loudness) = (0.25, 0.4)
    case "verse": (part.complexity, part.loudness) = (0.4, 0.5)
    case "pre-chorus": (part.complexity, part.loudness) = (0.5, 0.6)
    case "chorus": (part.complexity, part.loudness) = (0.6, 0.75)
    case "bridge": (part.complexity, part.loudness) = (0.5, 0.55)
    case "solo": (part.complexity, part.loudness) = (0.55, 0.7)
    case "breakdown": (part.complexity, part.loudness) = (0.2, 0.35)
    case "outro": (part.complexity, part.loudness) = (0.35, 0.55)
    default: break
    }
    part.leadsIntoNext = !isLast
    return part
  }

  // MARK: - Playing

  /// One note of the part, from the song's start: its pitches (a chord for the keys).
  struct Event {
    var position: Tick
    var pitches: [Int]
    var length: Tick
    var velocity: Double
  }

  private static let sixteenth = Tick(240)

  /// The notes the player plays from `start` for `length`, following `chords`, relative to
  /// `start`.
  public func notes(from start: Tick, length: Tick, tempoMap: TempoMap, chords: ChordTimeline) -> [MIDINote] {
    guard length > .zero else { return [] }
    let end = start + length
    var events: [Event] = []
    var random = SplitMix(seed: seed ^ 0x5E55_1011)
    // The key the region starts in, for passing notes.
    var bass = BassLine(player: self, key: chords.key(at: start))
    var keys = KeysLine(player: self, key: chords.key(at: start))
    let first = tempoMap.bar(containing: start)
    var barIndex = first.index
    var barStart = first.start
    while barStart < end {
      let signature = tempoMap.timeSignature(atBarIndex: barIndex)
      let barEnd = tempoMap.tickPosition(ofBarIndex: barIndex + 1)
      let pulses = DrummerPerformance.pulses(of: signature)
      let context = BarContext(
        start: barStart, end: barEnd, pulses: pulses, chords: chords, isLastBar: barEnd >= end, regionEnd: end)
      switch instrument {
      case .bass: bass.play(context, barInRegion: barIndex - first.index)
      case .keys: keys.play(context, barInRegion: barIndex - first.index)
      }
      barIndex += 1
      barStart = barEnd
    }
    events += bass.events + keys.events

    // Swing and a human touch, then the notes within the region.
    var notes: [MIDINote] = []
    for var event in events.sorted(by: { $0.position < $1.position }) {
      let step = (event.position - tempoMap.bar(containing: event.position).start).rawValue / Self.sixteenth.rawValue
      if swing > 0 {
        if style.swingsSixteenths, step % 2 == 1 {
          event.position += Tick(Int64(80 * swing))
        } else if !style.swingsSixteenths, step % 4 == 2 {
          event.position += Tick(Int64(160 * swing))
        }
      }
      guard event.position >= start, event.position < end else { continue }
      // A human touch, never pushing a note out of the region.
      event.position = min(max(start, event.position + Tick(Int64(((random.unit() - 0.5) * 12).rounded()))), end - Tick(1))
      let velocity = event.velocity + (random.unit() - 0.5) * 8
      for pitch in event.pitches where MIDINote.pitchRange.contains(pitch) {
        notes.append(MIDINote(
          pitch: pitch, velocity: min(max(Int(velocity.rounded()), 1), 127), start: event.position - start,
          length: max(Tick(30), min(event.length, end - event.position))))
      }
    }
    return notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
  }

  struct BarContext {
    var start: Tick
    var end: Tick
    var pulses: [DrummerPerformance.Pulse]
    var chords: ChordTimeline
    var isLastBar: Bool
    var regionEnd: Tick

    func position(_ step: Int) -> Tick { start + PlayerPerformance.sixteenth * Int64(step) }
    func chord(at step: Int) -> Chord { chords.chord(at: position(step)) }
    var steps: Int { pulses.last.map { $0.step + $0.length } ?? 16 }
    /// The step where the chord changes after `step` (or the bar's end).
    func nextChange(after step: Int) -> Int {
      let chord = chord(at: step)
      for later in (step + 1)..<max(step + 1, steps) where self.chord(at: later) != chord { return later }
      return steps
    }
  }
}

/// The chords a player follows: the Chord track's changes, and the chord to use where it has
/// none (the key's).
public struct ChordTimeline: Sendable {
  public var changes: [ChordChange]
  public var fallback: Chord
  /// The song's key at the start, for the passing notes between chord tones.
  public var key: KeySignature
  /// Where the key changes after the start, sorted (see `Project.keyChanges`).
  public var keyChanges: [KeyChange]

  public init(changes: [ChordChange], fallback: Chord, key: KeySignature = .cMajor, keyChanges: [KeyChange] = []) {
    self.changes = changes.sorted { $0.position < $1.position }
    self.fallback = fallback
    self.key = key
    self.keyChanges = keyChanges.sorted { $0.position < $1.position }
  }

  public func key(at position: Tick) -> KeySignature {
    keyChanges.last { $0.position <= position }?.key ?? key
  }

  /// The chord at `position`; with no chords at all, the home chord of the key there.
  public func chord(at position: Tick) -> Chord {
    if let chord = changes.last(where: { $0.position <= position })?.chord ?? changes.first?.chord { return chord }
    guard !keyChanges.isEmpty else { return fallback }
    let key = key(at: position)
    return Chord(root: key.tonic, quality: key.mode == .minor ? .minor : .major)
  }
}

extension Project {
  /// The Chord track, for the players.
  public var chordTimeline: ChordTimeline {
    ChordTimeline(
      changes: chords, fallback: Chord(root: keySignature.tonic, quality: keySignature.mode == .minor ? .minor : .major),
      key: keySignature, keyChanges: keyChanges)
  }

  /// Plays every session player region again, after the chords or the meter changed.
  mutating func renderPlayerRegions() {
    let timeline = chordTimeline
    for trackIndex in tracks.indices {
      for regionIndex in tracks[trackIndex].regions.indices where tracks[trackIndex].regions[regionIndex].player != nil {
        tracks[trackIndex].regions[regionIndex].renderPlayer(tempoMap: tempoMap, chords: timeline)
      }
    }
  }
}

extension Region {
  /// For a session player region, replaces its notes with what the player plays over its
  /// length.
  public mutating func renderPlayer(tempoMap: TempoMap, chords: ChordTimeline) {
    guard let player, case .midi(var sequence) = content else { return }
    sequence.notes = player.notes(from: start, length: length, tempoMap: tempoMap, chords: chords)
    content = .midi(sequence)
  }

  public mutating func renderPlayer(in project: Project) {
    renderPlayer(tempoMap: project.tempoMap, chords: project.chordTimeline)
  }

  public var isPlayerRegion: Bool { player != nil }
}

/// Changes session player regions' performances, playing their notes again.
public struct SetPlayerPerformance: EditCommand {
  public var regionIDs: Set<Region.ID>
  public var change: @Sendable (inout PlayerPerformance) -> Void
  public var actionName: String

  public init(
    for regionIDs: Set<Region.ID>, actionName: String = "Edit Player", change: @escaping @Sendable (inout PlayerPerformance) -> Void
  ) {
    self.regionIDs = regionIDs
    self.change = change
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    let timeline = project.chordTimeline
    var changed = false
    for trackIndex in project.tracks.indices {
      for regionIndex in project.tracks[trackIndex].regions.indices
      where regionIDs.contains(project.tracks[trackIndex].regions[regionIndex].id) {
        guard var player = project.tracks[trackIndex].regions[regionIndex].player else { continue }
        change(&player)
        player.complexity = min(max(player.complexity, 0), 1)
        player.loudness = min(max(player.loudness, 0), 1)
        player.swing = min(max(player.swing, 0), 1)
        player.register = min(max(player.register, PlayerPerformance.registerRange.lowerBound), PlayerPerformance.registerRange.upperBound)
        project.tracks[trackIndex].regions[regionIndex].player = player
        project.tracks[trackIndex].regions[regionIndex].renderPlayer(tempoMap: project.tempoMap, chords: timeline)
        changed = true
      }
    }
    guard changed else { throw EditError.invalidValue("Select a session player region.") }
  }
}
