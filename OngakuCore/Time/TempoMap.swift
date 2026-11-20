//
//  TempoMap.swift
//  OngakuCore
//

import Foundation

/// Converts between musical time (ticks, bars and beats) and real time (seconds and samples).
///
/// A tempo map always has a tempo change at tick 0 and a meter change at bar index 0. Tempo
/// changes step, or ramp linearly (in BPM) to the next change when `rampsToNext` is set;
/// times through a ramp are worked out exactly.
public struct TempoMap: Codable, Sendable, Equatable {
  public struct TempoChange: Codable, Sendable, Equatable {
    public var position: Tick
    public var bpm: Double
    /// Whether the tempo glides from this change to the next (a linear ramp in BPM, as
    /// Logic's tempo curves) instead of stepping there.
    public var rampsToNext: Bool

    public init(position: Tick, bpm: Double, rampsToNext: Bool = false) {
      self.position = position
      self.bpm = bpm
      self.rampsToNext = rampsToNext
    }

    private enum CodingKeys: String, CodingKey {
      case position, bpm, rampsToNext
    }

    // Ramps were added in format version 30; older changes step.
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      position = try container.decode(Tick.self, forKey: .position)
      bpm = try container.decode(Double.self, forKey: .bpm)
      rampsToNext = try container.decodeIfPresent(Bool.self, forKey: .rampsToNext) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(position, forKey: .position)
      try container.encode(bpm, forKey: .bpm)
      if rampsToNext { try container.encode(true, forKey: .rampsToNext) }
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
    guard let index = tempoChanges.lastIndex(where: { $0.position <= position }) else { return tempoChanges[0].bpm }
    let change = tempoChanges[index]
    guard change.rampsToNext, index + 1 < tempoChanges.count else { return change.bpm }
    let next = tempoChanges[index + 1]
    let fraction = Double((position - change.position).rawValue) / Double((next.position - change.position).rawValue)
    return change.bpm + (next.bpm - change.bpm) * fraction
  }

  /// Makes the tempo change at `position` ramp to the next one, or step again. The last
  /// change has nothing to ramp to.
  public mutating func setRamp(_ ramps: Bool, at position: Tick) {
    guard let index = tempoChanges.firstIndex(where: { $0.position == position }) else { return }
    tempoChanges[index].rampsToNext = ramps
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
    // The last change has nothing to ramp to.
    tempoChanges[tempoChanges.count - 1].rampsToNext = false
  }

  // MARK: - Section edits

  /// Moves the tempo and meter changes after the start, for an edit that moves time around
  /// (see `Project.remapTimeline`). `newPosition` returns `nil` to delete a change. Meter
  /// changes land on the bar line at or after their new position. Changes that end up
  /// repeating the tempo or meter already playing are dropped.
  mutating func remapChanges(_ newPosition: (Tick) -> Tick?) {
    let old = self
    var tempos: [Tick: TempoChange] = [:]
    for change in tempoChanges.dropFirst() {
      guard let position = newPosition(change.position), position > .zero else { continue }
      tempos[position] = TempoChange(position: position, bpm: change.bpm, rampsToNext: change.rampsToNext)
    }
    tempoChanges = [tempoChanges[0]]
    for (_, change) in tempos.sorted(by: { $0.key < $1.key }) {
      // A change repeating the tempo before it is dropped, unless a ramp runs to or from it.
      let previous = tempoChanges[tempoChanges.count - 1]
      guard change.bpm != previous.bpm || previous.rampsToNext || change.rampsToNext else { continue }
      tempoChanges.append(change)
    }
    // The last change has nothing to ramp to.
    tempoChanges[tempoChanges.count - 1].rampsToNext = false

    let meters = meterChanges.dropFirst().compactMap { change -> (position: Tick, signature: TimeSignature)? in
      guard let position = newPosition(old.tickPosition(ofBarIndex: change.barIndex)), position > .zero else { return nil }
      return (position, change.signature)
    }
    meterChanges = [meterChanges[0]]
    for meter in meters.sorted(by: { $0.position < $1.position }) {
      // Bars are counted in the meters placed so far, so each lands on a bar line.
      let bar = bar(containing: meter.position)
      let index = bar.start == meter.position ? bar.index : bar.index + 1
      meterChanges.removeAll { $0.barIndex >= index && $0.barIndex > 0 }
      guard timeSignature(atBarIndex: index) != meter.signature else { continue }
      meterChanges.append(MeterChange(barIndex: index, signature: meter.signature))
    }
  }

  // MARK: - Ticks ↔ seconds ↔ samples

  /// The tempo at the start of segment `index` and how fast it changes per tick through
  /// it (0 when it steps).
  private func slope(ofSegment index: Int) -> (bpm: Double, perTick: Double) {
    let change = tempoChanges[index]
    guard change.rampsToNext, index + 1 < tempoChanges.count else { return (change.bpm, 0) }
    let next = tempoChanges[index + 1]
    return (change.bpm, (next.bpm - change.bpm) / Double((next.position - change.position).rawValue))
  }

  /// Seconds from the start of segment `index` to `ticks` into it. Through a ramp the tempo
  /// is b + k·x BPM at x ticks, so the time is ∫ 60 / (960 (b + k x)) dx = (60/960) ln(1 + k x / b) / k.
  private func seconds(intoSegment index: Int, ticks: Double) -> Double {
    let (bpm, perTick) = slope(ofSegment: index)
    let secondsPerBeatTick = 60 / Double(Tick.perQuarterNote)
    guard abs(perTick) > 1e-12 else { return ticks * secondsPerBeatTick / bpm }
    return secondsPerBeatTick * log1p(perTick * ticks / bpm) / perTick
  }

  /// The inverse: ticks into segment `index` after `seconds` (b (e^{k s′} − 1) / k, with s′
  /// the seconds in beat-ticks).
  private func ticks(intoSegment index: Int, seconds: Double) -> Double {
    let (bpm, perTick) = slope(ofSegment: index)
    let scaled = seconds * Double(Tick.perQuarterNote) / 60
    guard abs(perTick) > 1e-12 else { return scaled * bpm }
    return bpm * expm1(perTick * scaled) / perTick
  }

  public func seconds(at position: Tick) -> Double {
    var elapsed = 0.0
    for (index, change) in tempoChanges.enumerated() {
      if index + 1 < tempoChanges.count, position > tempoChanges[index + 1].position {
        elapsed += seconds(intoSegment: index, ticks: Double((tempoChanges[index + 1].position - change.position).rawValue))
      } else {
        return elapsed + seconds(intoSegment: index, ticks: Double((position - change.position).rawValue))
      }
    }
    return elapsed
  }

  /// The tick nearest to a time in seconds from the project start.
  public func tickPosition(atSeconds seconds: Double) -> Tick {
    var elapsed = 0.0
    for (index, change) in tempoChanges.enumerated() {
      if index + 1 < tempoChanges.count {
        let segmentTicks = tempoChanges[index + 1].position - change.position
        let segmentSeconds = self.seconds(intoSegment: index, ticks: Double(segmentTicks.rawValue))
        if seconds > elapsed + segmentSeconds {
          elapsed += segmentSeconds
          continue
        }
      }
      return change.position + Tick(Int64(ticks(intoSegment: index, seconds: seconds - elapsed).rounded()))
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
