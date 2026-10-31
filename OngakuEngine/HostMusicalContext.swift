//
//  HostMusicalContext.swift
//  OngakuEngine
//

import AudioToolbox
import OngakuCore
import Synchronization

/// The song's tempo, time signature and position, for plug-ins that follow them (a delay
/// synced to the beat, for example). The engine updates it as the playhead moves; plug-ins
/// read it from the render thread through `block`, so it's kept in atomics.
public final class HostMusicalContext: Sendable {
  private let tempo = Atomic<UInt64>(120.0.bitPattern)
  private let beat = Atomic<UInt64>(0.0.bitPattern)
  private let numerator = Atomic<Int>(4)
  private let denominator = Atomic<Int>(4)

  public init() {}

  /// Takes the tempo and signature at `position` in the song.
  public func update(at position: Tick, in tempoMap: TempoMap) {
    tempo.store(tempoMap.tempo(at: position).bitPattern, ordering: .relaxed)
    beat.store((Double(position.rawValue) / Double(Tick.perQuarterNote)).bitPattern, ordering: .relaxed)
    let signature = tempoMap.timeSignature(atBarIndex: tempoMap.bar(containing: position).index)
    numerator.store(signature.beatsPerBar, ordering: .relaxed)
    denominator.store(signature.beatUnit, ordering: .relaxed)
  }

  public var currentTempo: Double { Double(bitPattern: tempo.load(ordering: .relaxed)) }

  /// The block Audio Units call for the musical context.
  public var block: AUHostMusicalContextBlock {
    { [self] tempoOut, numeratorOut, denominatorOut, beatOut, sampleOffsetOut, downbeatOut in
      tempoOut?.pointee = Double(bitPattern: tempo.load(ordering: .relaxed))
      numeratorOut?.pointee = Double(numerator.load(ordering: .relaxed))
      denominatorOut?.pointee = denominator.load(ordering: .relaxed)
      beatOut?.pointee = Double(bitPattern: beat.load(ordering: .relaxed))
      sampleOffsetOut?.pointee = 0
      downbeatOut?.pointee = 0
      return true
    }
  }
}
