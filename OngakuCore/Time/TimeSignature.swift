//
//  TimeSignature.swift
//  OngakuCore
//

import Foundation

/// A meter such as 4/4 or 6/8.
public struct TimeSignature: Hashable, Codable, Sendable, CustomStringConvertible {
  /// Beat units Ongaku supports. Each must divide a whole note into a whole number of ticks
  /// and be at least one division (a sixteenth note) long.
  public static let supportedBeatUnits: Set<Int> = [1, 2, 4, 8, 16]
  public static let beatsPerBarRange = 1...64

  public static let fourFour = TimeSignature(beatsPerBar: 4, beatUnit: 4)

  /// The meters Logic offers first, for menus.
  public static let common: [TimeSignature] = [
    (2, 4), (3, 4), (4, 4), (5, 4), (6, 4), (7, 4), (2, 2), (3, 8), (5, 8), (6, 8), (7, 8), (9, 8), (12, 8),
  ].map { TimeSignature(beatsPerBar: $0, beatUnit: $1) }

  /// The numerator.
  public var beatsPerBar: Int
  /// The denominator.
  public var beatUnit: Int

  public init(beatsPerBar: Int, beatUnit: Int) {
    self.beatsPerBar = beatsPerBar
    self.beatUnit = beatUnit
  }

  public var isValid: Bool {
    TimeSignature.beatsPerBarRange.contains(beatsPerBar)
      && TimeSignature.supportedBeatUnits.contains(beatUnit)
  }

  public var ticksPerBeat: Tick {
    Tick(Tick.perQuarterNote * 4 / Int64(beatUnit))
  }

  public var ticksPerBar: Tick {
    ticksPerBeat * Int64(beatsPerBar)
  }

  /// A compound meter (6/8, 9/8, 12/8…): its beats are felt in groups of three, each a
  /// dotted note, the way 4/4 with triplets feels.
  public var isCompound: Bool {
    beatsPerBar >= 6 && beatsPerBar % 3 == 0 && beatUnit >= 8
  }

  /// The felt beat: a group of three in a compound meter, otherwise the beat.
  public var pulse: Tick {
    isCompound ? ticksPerBeat * 3 : ticksPerBeat
  }

  public var description: String { "\(beatsPerBar)/\(beatUnit)" }
}

/// A position expressed the way Logic's LCD shows it: bar, beat, division and tick.
///
/// Bar, beat and division are 1-based; `tick` is the 0-based remainder inside the division.
/// The division is a sixteenth note (Logic's default display division).
public struct MusicalPosition: Hashable, Sendable, CustomStringConvertible {
  public static let ticksPerDivision = Tick(Tick.perQuarterNote / 4)

  public var bar: Int
  public var beat: Int
  public var division: Int
  public var tick: Int

  public init(bar: Int, beat: Int = 1, division: Int = 1, tick: Int = 0) {
    self.bar = bar
    self.beat = beat
    self.division = division
    self.tick = tick
  }

  public var description: String { "\(bar) \(beat) \(division) \(tick + 1)" }
}
