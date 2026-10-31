//
//  Tick.swift
//  OngakuCore
//

import Foundation

/// A position or duration in musical time.
///
/// Ongaku stores every musical position in ticks at a fixed resolution of 960 ticks per
/// quarter note (the same resolution Logic Pro uses). Ticks are independent of tempo, so a
/// tempo change never moves notes or regions; `TempoMap` converts ticks to seconds and
/// samples when the engine needs real time.
public struct Tick: RawRepresentable, Hashable, Comparable, Codable, Sendable,
  AdditiveArithmetic, ExpressibleByIntegerLiteral, CustomStringConvertible
{
  public static let perQuarterNote: Int64 = 960

  public var rawValue: Int64

  public init(rawValue: Int64) {
    self.rawValue = rawValue
  }

  public init(_ value: Int64) {
    self.rawValue = value
  }

  public init(integerLiteral value: Int64) {
    self.rawValue = value
  }

  public static let zero = Tick(0)

  /// Creates a tick value from a (possibly fractional) number of quarter notes.
  public static func quarterNotes(_ count: Double) -> Tick {
    Tick(Int64((count * Double(perQuarterNote)).rounded()))
  }

  public var quarterNotes: Double {
    Double(rawValue) / Double(Tick.perQuarterNote)
  }

  public var description: String { "\(rawValue)t" }

  public static func < (lhs: Tick, rhs: Tick) -> Bool { lhs.rawValue < rhs.rawValue }
  public static func + (lhs: Tick, rhs: Tick) -> Tick { Tick(lhs.rawValue + rhs.rawValue) }
  public static func - (lhs: Tick, rhs: Tick) -> Tick { Tick(lhs.rawValue - rhs.rawValue) }
  public static func * (lhs: Tick, rhs: Int64) -> Tick { Tick(lhs.rawValue * rhs) }
  public static func * (lhs: Int64, rhs: Tick) -> Tick { Tick(lhs * rhs.rawValue) }
}
