//
//  TempoMap.swift
//  OngakuCore
//

import Foundation

/// Converts between musical time (ticks, bars and beats) and real time (seconds and samples).
///
/// A tempo map always has a tempo change at tick 0 and a meter change at bar index 0. Tempo
/// changes are instantaneous steps; tempo ramps can be added later as a new segment kind
/// without changing how positions are stored.
public struct TempoMap: Codable, Sendable, Equatable {
  public struct TempoChange: Codable, Sendable, Equatable {
    public var position: Tick
    public var bpm: Double

    public init(position: Tick, bpm: Double) {
      self.position = position
      self.bpm = bpm
    }
  }

  public struct MeterChange: Codable, Sendable, Equatable {
    /// 0-based bar index (bar 1 on the ruler is index 0).
    public var barIndex: Int
    public var signature: TimeSignature

    public init(barIndex: Int, signature: TimeSignature) {
      self.barIndex = barIndex
      self.signature = signature
    }
  }

  public static let bpmRange: ClosedRange<Double> = 5...990

  /// Sorted by position; the first change is always at tick 0.
  public private(set) var tempoChanges: [TempoChange]
  /// Sorted by bar index; the first change is always at bar index 0.
  public private(set) var meterChanges: [MeterChange]

  public init(bpm: Double = 120, timeSignature: TimeSignature = .fourFour) {
    let clampedBPM = min(max(bpm, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound)
    tempoChanges = [TempoChange(position: .zero, bpm: clampedBPM)]
    meterChanges = [MeterChange(barIndex: 0, signature: timeSignature.isValid ? timeSignature : .fourFour)]
  }

  private enum CodingKeys: String, CodingKey {
    case tempoChanges, meterChanges
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tempos = try container.decode([TempoChange].self, forKey: .tempoChanges)
      .sorted { $0.position < $1.position }
    let meters = try container.decode([MeterChange].self, forKey: .meterChanges)
      .sorted { $0.barIndex < $1.barIndex }
    guard tempos.first?.position == .zero,
      tempos.allSatisfy({ TempoMap.bpmRange.contains($0.bpm) }),
      meters.first?.barIndex == 0,
      meters.allSatisfy({ $0.signature.isValid })
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid tempo map"))
    }
    tempoChanges = tempos
    meterChanges = meters
  }

  // MARK: - Tempo

  public func tempo(at position: Tick) -> Double {
    tempoChanges.last(where: { $0.position <= position })?.bpm ?? tempoChanges[0].bpm
  }

  public mutating func setTempo(_ bpm: Double, at position: Tick = .zero) throws {
    guard TempoMap.bpmRange.contains(bpm) else {
      throw EditError.invalidValue(
        "Tempo must be between \(Int(TempoMap.bpmRange.lowerBound)) and \(Int(TempoMap.bpmRange.upperBound)) BPM.")
    }
    guard position >= .zero else {
      throw EditError.invalidValue("Tempo changes can’t be placed before the project start.")
    }
    if let index = tempoChanges.firstIndex(where: { $0.position == position }) {
      tempoChanges[index].bpm = bpm
    } else {
      let insertionIndex = tempoChanges.firstIndex { $0.position > position } ?? tempoChanges.count
      tempoChanges.insert(TempoChange(position: position, bpm: bpm), at: insertionIndex)
    }
  }

  /// Removes a tempo change. The initial tempo at tick 0 can be changed but not removed.
  public mutating func removeTempoChange(at position: Tick) {
    guard position != .zero else { return }
    tempoChanges.removeAll { $0.position == position }
  }

  // MARK: - Ticks ↔ seconds ↔ samples

  private static func secondsPerTick(atBPM bpm: Double) -> Double {
    60 / (bpm * Double(Tick.perQuarterNote))
  }

  public func seconds(at position: Tick) -> Double {
    var elapsed = 0.0
    for (index, change) in tempoChanges.enumerated() {
      let secondsPerTick = TempoMap.secondsPerTick(atBPM: change.bpm)
      if index + 1 < tempoChanges.count, position > tempoChanges[index + 1].position {
        elapsed += Double((tempoChanges[index + 1].position - change.position).rawValue) * secondsPerTick
      } else {
        return elapsed + Double((position - change.position).rawValue) * secondsPerTick
      }
    }
    return elapsed
  }

  /// The tick nearest to a time in seconds from the project start.
  public func tickPosition(atSeconds seconds: Double) -> Tick {
    var elapsed = 0.0
    for (index, change) in tempoChanges.enumerated() {
      let secondsPerTick = TempoMap.secondsPerTick(atBPM: change.bpm)
      if index + 1 < tempoChanges.count {
        let segmentTicks = tempoChanges[index + 1].position - change.position
        let segmentSeconds = Double(segmentTicks.rawValue) * secondsPerTick
        if seconds > elapsed + segmentSeconds {
          elapsed += segmentSeconds
          continue
        }
      }
      return change.position + Tick(Int64(((seconds - elapsed) / secondsPerTick).rounded()))
    }
    return .zero
  }

  public func sampleTime(at position: Tick, sampleRate: Double) -> Int64 {
    Int64((seconds(at: position) * sampleRate).rounded())
  }

  public func tickPosition(atSampleTime sampleTime: Int64, sampleRate: Double) -> Tick {
    tickPosition(atSeconds: Double(sampleTime) / sampleRate)
  }

  // MARK: - Meter

  public func timeSignature(atBarIndex barIndex: Int) -> TimeSignature {
    meterChanges.last(where: { $0.barIndex <= barIndex })?.signature ?? meterChanges[0].signature
  }

  public mutating func setTimeSignature(_ signature: TimeSignature, atBarIndex barIndex: Int) throws {
    guard signature.isValid else {
      throw EditError.invalidValue("\(signature) isn’t a supported time signature.")
    }
    guard barIndex >= 0 else {
      throw EditError.invalidValue("Time signature changes can’t be placed before bar 1.")
    }
    if let index = meterChanges.firstIndex(where: { $0.barIndex == barIndex }) {
      meterChanges[index].signature = signature
    } else {
      let insertionIndex = meterChanges.firstIndex { $0.barIndex > barIndex } ?? meterChanges.count
      meterChanges.insert(MeterChange(barIndex: barIndex, signature: signature), at: insertionIndex)
    }
  }

  /// Removes a meter change. The initial time signature can be changed but not removed.
  public mutating func removeTimeSignatureChange(atBarIndex barIndex: Int) {
    guard barIndex != 0 else { return }
    meterChanges.removeAll { $0.barIndex == barIndex }
  }

  /// The tick at which a bar starts. Negative bar indexes extend the first meter backwards
  /// (for count-in and pre-roll).
  public func tickPosition(ofBarIndex barIndex: Int) -> Tick {
    var position = Tick.zero
    for (index, change) in meterChanges.enumerated() {
      let barLength = change.signature.ticksPerBar
      if index + 1 < meterChanges.count, barIndex >= meterChanges[index + 1].barIndex {
        position += barLength * Int64(meterChanges[index + 1].barIndex - change.barIndex)
      } else {
        return position + barLength * Int64(barIndex - change.barIndex)
      }
    }
    return position
  }

  /// The 0-based index of the bar containing `position`, and the tick at which that bar starts.
  public func bar(containing position: Tick) -> (index: Int, start: Tick) {
    var segmentStart = Tick.zero
    for (index, change) in meterChanges.enumerated() {
      let barLength = change.signature.ticksPerBar
      if index + 1 < meterChanges.count {
        let segmentBars = Int64(meterChanges[index + 1].barIndex - change.barIndex)
        let segmentEnd = segmentStart + barLength * segmentBars
        if position >= segmentEnd {
          segmentStart = segmentEnd
          continue
        }
      }
      let barsIntoSegment = floorDivide((position - segmentStart).rawValue, barLength.rawValue)
      return (change.barIndex + Int(barsIntoSegment), segmentStart + barLength * barsIntoSegment)
    }
    return (0, .zero)
  }

  public func musicalPosition(at position: Tick) -> MusicalPosition {
    let (barIndex, barStart) = bar(containing: position)
    let signature = timeSignature(atBarIndex: barIndex)
    let ticksPerBeat = signature.ticksPerBeat.rawValue
    let ticksPerDivision = MusicalPosition.ticksPerDivision.rawValue

    var remainder = (position - barStart).rawValue
    let beat = remainder / ticksPerBeat
    remainder %= ticksPerBeat
    let division = remainder / ticksPerDivision
    remainder %= ticksPerDivision

    return MusicalPosition(
      bar: barIndex + 1, beat: Int(beat) + 1, division: Int(division) + 1, tick: Int(remainder))
  }

  public func tickPosition(of musicalPosition: MusicalPosition) -> Tick {
    let barIndex = musicalPosition.bar - 1
    let signature = timeSignature(atBarIndex: barIndex)
    return tickPosition(ofBarIndex: barIndex)
      + signature.ticksPerBeat * Int64(musicalPosition.beat - 1)
      + MusicalPosition.ticksPerDivision * Int64(musicalPosition.division - 1)
      + Tick(Int64(musicalPosition.tick))
  }
}

/// Integer division that rounds towards negative infinity (so tick -1 is in bar 0, not bar 1).
private func floorDivide(_ dividend: Int64, _ divisor: Int64) -> Int64 {
  let quotient = dividend / divisor
  let hasRemainder = dividend % divisor != 0
  return hasRemainder && (dividend < 0) != (divisor < 0) ? quotient - 1 : quotient
}
