//
//  StepPattern.swift
//  OngakuCore
//

import Foundation

/// A Step Sequencer pattern, as in Logic: rows of steps (each a drum, or a pitch), looping
/// through a region. Each row can have its own length and rate, so rows of different
/// lengths drift against each other for polyrhythms.
///
/// A pattern region is a MIDI region that has a pattern: its notes are rendered from the
/// pattern (see `Region.renderPattern()`), so everything that plays or reads notes works on
/// it unchanged.
public struct StepPattern: Codable, Sendable, Equatable {
  public var rows: [Row]
  /// Steps in the pattern (a row's own length can differ).
  public var length: Int
  public var rate: NoteDivision
  /// Delays every second step, toward a triplet feel at 1 (0 is straight).
  public var swing: Double

  public static let lengthRange: ClosedRange<Int> = 1...64

  public init(rows: [Row] = [], length: Int = 16, rate: NoteDivision = .sixteenth, swing: Double = 0) {
    self.rows = rows
    self.length = length
    self.rate = rate
    self.swing = swing
  }

  /// One row: a note, its steps, and how it plays them.
  public struct Row: Identifiable, Codable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable, CaseIterable, Identifiable {
      case forward, backward, pingPong, random
      public var id: Self { self }
      public var title: String {
        switch self {
        case .forward: "Forward"
        case .backward: "Backward"
        case .pingPong: "Ping-Pong"
        case .random: "Random"
        }
      }
    }

    public var id: UUID
    public var pitch: Int
    public var name: String
    /// As many as the row is long (its own length, or the pattern's).
    public var steps: [Step]
    /// The row's own length in steps; `nil` follows the pattern's.
    public var length: Int?
    /// The row's own rate; `nil` follows the pattern's.
    public var rate: NoteDivision?
    public var direction: Direction
    public var isMuted: Bool

    public init(
      id: UUID = UUID(), pitch: Int, name: String, steps: [Step] = [], length: Int? = nil, rate: NoteDivision? = nil,
      direction: Direction = .forward, isMuted: Bool = false
    ) {
      self.id = id
      self.pitch = pitch
      self.name = name
      self.steps = steps
      self.length = length
      self.rate = rate
      self.direction = direction
      self.isMuted = isMuted
    }
  }

  /// One step of a row.
  public struct Step: Codable, Sendable, Equatable {
    public var isOn: Bool
    public var velocity: Int
    /// How long the note plays, as a fraction of the step (0.05–1).
    public var gate: Double
    /// How likely the step is to play, in percent (it plays the same way every time).
    public var chance: Double
    /// Plays this many notes in the step (a roll), 1–4.
    public var repeats: Int

    public init(isOn: Bool = false, velocity: Int = 100, gate: Double = 0.8, chance: Double = 100, repeats: Int = 1) {
      self.isOn = isOn
      self.velocity = velocity
      self.gate = gate
      self.chance = chance
      self.repeats = repeats
    }
  }

  // MARK: - Starting points

  /// The drums a kit's rows start with, top to bottom, with General MIDI notes.
  public static let drumRows: [(pitch: Int, name: String)] = [
    (36, "Kick"), (38, "Snare"), (39, "Clap"), (42, "Closed Hat"), (46, "Open Hat"), (45, "Low Tom"), (47, "Mid Tom"),
    (50, "High Tom"), (49, "Crash"), (51, "Ride"),
  ]

  /// A drum pattern with a simple beat to start from: the kick on beats 1 and 3, the snare
  /// on 2 and 4, eighth-note hats.
  public static func drums(length: Int = 16) -> StepPattern {
    var pattern = StepPattern(length: length)
    pattern.rows = drumRows.map { Row(pitch: $0.pitch, name: $0.name, steps: Array(repeating: Step(), count: length)) }
    for index in pattern.rows.indices {
      for step in 0..<length {
        let beat = step % 16
        switch pattern.rows[index].pitch {
        case 36 where beat == 0 || beat == 8: pattern.rows[index].steps[step] = Step(isOn: true, velocity: 115)
        case 38 where beat == 4 || beat == 12: pattern.rows[index].steps[step] = Step(isOn: true, velocity: 110)
        case 42 where beat % 2 == 0: pattern.rows[index].steps[step] = Step(isOn: true, velocity: beat % 4 == 0 ? 95 : 70, gate: 0.5)
        default: break
        }
      }
    }
    return pattern
  }

  /// An empty pattern of a scale's notes, highest first: C major from `root`, an octave.
  public static func notes(root: Int = 60, length: Int = 16) -> StepPattern {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let pitches = [0, 2, 4, 5, 7, 9, 11, 12].map { root + $0 }.reversed()
    return StepPattern(rows: pitches.map { pitch in
      Row(pitch: pitch, name: "\(names[pitch % 12])\(pitch / 12 - 2)", steps: Array(repeating: Step(), count: length))
    }, length: length)
  }

  // MARK: - Playing

  /// A row's length in steps, and its rate.
  public func length(of row: Row) -> Int { max(1, row.length ?? length) }
  public func rate(of row: Row) -> NoteDivision { row.rate ?? rate }

  /// Which of a row's steps plays at its `count`-th step from the region start.
  public func stepIndex(of row: Row, at count: Int) -> Int {
    let length = length(of: row)
    switch row.direction {
    case .forward: return count % length
    case .backward: return length - 1 - count % length
    case .pingPong:
      guard length > 1 else { return 0 }
      let cycle = count % (2 * length - 2)
      return cycle < length ? cycle : 2 * length - 2 - cycle
    case .random:
      var random = SplitMix(seed: Self.seed(row.id, count))
      return Int(random.next() % UInt64(length))
    }
  }

  /// The notes the pattern plays over `length` (from the region start), each row stepping
  /// through its steps at its rate and looping at its length.
  public func notes(over regionLength: Tick) -> [MIDINote] {
    var notes: [MIDINote] = []
    for row in rows where !row.isMuted {
      let step = rate(of: row).ticks
      guard step > .zero else { continue }
      var count = 0
      while step * Int64(count) < regionLength {
        let index = stepIndex(of: row, at: count)
        if row.steps.indices.contains(index) {
          let settings = row.steps[index]
          if settings.isOn, plays(settings, row: row, count: count) {
            var start = step * Int64(count)
            if count % 2 == 1 { start += Tick(Int64((Double(step.rawValue) * min(max(swing, 0), 1) / 3).rounded())) }
            let repeats = min(max(settings.repeats, 1), 4)
            let slot = Tick(step.rawValue / Int64(repeats))
            for repeatIndex in 0..<repeats {
              let noteStart = start + slot * Int64(repeatIndex)
              guard noteStart < regionLength else { break }
              let length = Tick(max(1, Int64((Double(slot.rawValue) * min(max(settings.gate, 0.05), 1)).rounded())))
              notes.append(MIDINote(
                pitch: min(max(row.pitch, MIDINote.pitchRange.lowerBound), MIDINote.pitchRange.upperBound),
                velocity: min(max(settings.velocity, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound),
                start: noteStart, length: length))
            }
          }
        }
        count += 1
      }
    }
    return notes.sorted { $0.start < $1.start }
  }

  /// Whether a step with a chance below 100 % plays this time round (the same each time
  /// the region plays: it's worked out from the row and step).
  private func plays(_ step: Step, row: Row, count: Int) -> Bool {
    guard step.chance < 100 else { return true }
    var random = SplitMix(seed: Self.seed(row.id, count) ^ 0xC4A2_CE00)
    return random.unit() * 100 < step.chance
  }

  private static func seed(_ id: UUID, _ count: Int) -> UInt64 {
    let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
    let high = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return high ^ (UInt64(count) &* 0x9E37_79B9_7F4A_7C15)
  }
}

extension Region {
  /// For a pattern region, replaces its notes with what its pattern plays over its length.
  /// Call after changing the pattern or the region's length.
  public mutating func renderPattern() {
    guard let pattern, case .midi(var sequence) = content else { return }
    sequence.notes = pattern.notes(over: length)
    content = .midi(sequence)
  }

  public var isPatternRegion: Bool { pattern != nil }
}
